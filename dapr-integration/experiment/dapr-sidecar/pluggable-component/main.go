// A Dapr PLUGGABLE pub/sub component for Apache Pulsar that authenticates to the
// broker with a CLIENT CERTIFICATE (mTLS) — the thing the built-in pubsub.pulsar
// component cannot do.
//
// It registers over a Unix socket named "pulsar-pluggable", so daprd loads it as
// component type "pubsub.pulsar-pluggable" (matching daprPubSub.yaml). The client
// cert/key/CA come from the component metadata (tlsCertFile/tlsKeyFile/
// tlsTrustCertsFilePath), i.e. "the cert is configured in the Dapr config".
//
// This is an open-source stand-in for the private ING pulsar-pluggable image: same
// component type, same metadata contract. In production, swap the image for yours.
package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/apache/pulsar-client-go/pulsar"
	dapr "github.com/dapr-sandbox/components-go-sdk"
	dpubsub "github.com/dapr-sandbox/components-go-sdk/pubsub/v1"
	"github.com/dapr/components-contrib/pubsub"
	"github.com/dapr/kit/logger"
)

var log = logger.NewLogger("pulsar-pluggable")

// PulsarPubSub implements github.com/dapr/components-contrib/pubsub.PubSub.
type PulsarPubSub struct {
	log    logger.Logger
	client pulsar.Client

	subType     pulsar.SubscriptionType
	subName     string
	subPosition pulsar.SubscriptionInitialPosition

	// topic addressing: persistent://<tenant>/<namespace>/<topic>
	tenant     string
	namespace  string
	persistent bool

	mu        sync.Mutex
	producers map[string]pulsar.Producer // one cached producer per fully-qualified topic
}

func NewPulsarPubSub(l logger.Logger) *PulsarPubSub {
	return &PulsarPubSub{log: l, producers: map[string]pulsar.Producer{}}
}

// Init builds the Pulsar client with mTLS client-cert auth from component metadata.
func (p *PulsarPubSub) Init(_ context.Context, md pubsub.Metadata) error {
	props := md.Properties

	serviceURL := firstNonEmpty(props["serviceUrl"], props["serviceURL"], props["host"])
	certFile := props["tlsCertFile"]
	keyFile := props["tlsKeyFile"]
	trustCerts := props["tlsTrustCertsFilePath"]
	if serviceURL == "" || certFile == "" || keyFile == "" {
		return errors.New("serviceUrl, tlsCertFile and tlsKeyFile are required")
	}

	p.subName = firstNonEmpty(props["subscriptionName"], "dapr-subscription")
	p.subType = parseSubType(props["subscriptionType"])
	p.subPosition = parsePosition(props["subscriptionInitialPosition"])

	p.tenant = firstNonEmpty(props["tenant"], "public")
	p.namespace = firstNonEmpty(props["namespace"], "default")
	p.persistent = props["persistent"] != "false" // default true

	p.log.Infof("connecting to Pulsar %s (mTLS client cert %s, verifyHostname=%s, allowInsecure=%s)",
		serviceURL, certFile, props["tlsEnableHostnameVerification"], props["tlsAllowInsecureConnection"])

	client, err := pulsar.NewClient(pulsar.ClientOptions{
		URL:                        serviceURL, // pulsar+ssl://host:6651
		Authentication:             pulsar.NewAuthenticationTLS(certFile, keyFile),
		TLSTrustCertsFilePath:      trustCerts,
		TLSAllowInsecureConnection: props["tlsAllowInsecureConnection"] == "true",
		TLSValidateHostname:        props["tlsEnableHostnameVerification"] == "true",
	})
	if err != nil {
		return fmt.Errorf("pulsar client init failed: %w", err)
	}
	p.client = client
	p.log.Info("Pulsar client ready")
	return nil
}

func (p *PulsarPubSub) Features() []pubsub.Feature { return nil }

func (p *PulsarPubSub) Publish(ctx context.Context, req *pubsub.PublishRequest) error {
	prod, err := p.producerFor(req.Topic)
	if err != nil {
		return err
	}
	_, err = prod.Send(ctx, &pulsar.ProducerMessage{
		Payload:    req.Data,
		Properties: req.Metadata,
	})
	if err != nil {
		return fmt.Errorf("publish to %q failed: %w", req.Topic, err)
	}
	return nil
}

func (p *PulsarPubSub) Subscribe(ctx context.Context, req pubsub.SubscribeRequest, handler pubsub.Handler) error {
	topic := p.fullTopic(req.Topic)
	consumer, err := p.client.Subscribe(pulsar.ConsumerOptions{
		Topic:                       topic,
		SubscriptionName:            p.subName,
		Type:                        p.subType,
		SubscriptionInitialPosition: p.subPosition,
	})
	if err != nil {
		return fmt.Errorf("subscribe to %q failed: %w", req.Topic, err)
	}

	go func() {
		defer consumer.Close()
		for {
			msg, err := consumer.Receive(ctx)
			if err != nil {
				if ctx.Err() != nil {
					return // context cancelled -> shutting down
				}
				p.log.Errorf("receive error on %q: %v", req.Topic, err)
				continue
			}
			nm := &pubsub.NewMessage{
				Topic:    req.Topic,
				Data:     msg.Payload(),
				Metadata: msg.Properties(),
			}
			if herr := handler(ctx, nm); herr != nil {
				p.log.Warnf("handler rejected message on %q: %v", req.Topic, herr)
				consumer.Nack(msg)
			} else {
				consumer.Ack(msg)
			}
		}
	}()
	return nil
}

// GetComponentMetadata is part of the contrib PubSub interface at the SDK's pin.
func (p *PulsarPubSub) GetComponentMetadata() map[string]string { return map[string]string{} }

func (p *PulsarPubSub) Close() error {
	p.mu.Lock()
	for _, prod := range p.producers {
		prod.Close()
	}
	p.producers = map[string]pulsar.Producer{}
	p.mu.Unlock()
	if p.client != nil {
		p.client.Close()
	}
	return nil
}

func (p *PulsarPubSub) producerFor(rawTopic string) (pulsar.Producer, error) {
	topic := p.fullTopic(rawTopic)
	p.mu.Lock()
	defer p.mu.Unlock()
	if prod, ok := p.producers[topic]; ok {
		return prod, nil
	}
	prod, err := p.client.CreateProducer(pulsar.ProducerOptions{Topic: topic})
	if err != nil {
		return nil, fmt.Errorf("create producer for %q failed: %w", topic, err)
	}
	p.producers[topic] = prod
	return prod, nil
}

// fullTopic turns a bare Dapr topic name into a Pulsar topic
// persistent://<tenant>/<namespace>/<topic>. A name that is already fully
// qualified (persistent:// or non-persistent://) is passed through unchanged.
func (p *PulsarPubSub) fullTopic(topic string) string {
	// daprd's HTTP router collapses "//" in the request path, so an unencoded
	// fully-qualified name can arrive as "persistent:/tenant/ns/topic" — repair it.
	for _, scheme := range []string{"persistent", "non-persistent"} {
		single := scheme + ":/"
		if strings.HasPrefix(topic, single) && !strings.HasPrefix(topic, scheme+"://") {
			topic = scheme + "://" + topic[len(single):]
			break
		}
	}
	if strings.HasPrefix(topic, "persistent://") || strings.HasPrefix(topic, "non-persistent://") {
		return topic
	}
	scheme := "persistent"
	if !p.persistent {
		scheme = "non-persistent"
	}
	return fmt.Sprintf("%s://%s/%s/%s", scheme, p.tenant, p.namespace, topic)
}

func parseSubType(s string) pulsar.SubscriptionType {
	switch s {
	case "exclusive", "Exclusive":
		return pulsar.Exclusive
	case "failover", "Failover":
		return pulsar.Failover
	case "keyshared", "key_shared", "KeyShared":
		return pulsar.KeyShared
	default:
		return pulsar.Shared
	}
}

func parsePosition(s string) pulsar.SubscriptionInitialPosition {
	switch s {
	case "earliest", "Earliest":
		return pulsar.SubscriptionPositionEarliest
	default:
		return pulsar.SubscriptionPositionLatest
	}
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func main() {
	// Creates /tmp/dapr-components-sockets/pulsar-pluggable.sock (shared with daprd),
	// so daprd resolves the component type as "pubsub.pulsar-pluggable".
	dapr.Register("pulsar-pluggable", dapr.WithPubSub(func() dpubsub.PubSub {
		return NewPulsarPubSub(log)
	}))
	dapr.MustRun()
}
