// CustomClient.java — single-file Java (JEP 330), pure JDK 21, no external deps.
//
// Run with:  java CustomClient.java   (needs the eclipse-temurin:21-jdk image, not -jre)
//
// What it does:
//   * Serves an HTTPS endpoint on APP_PORT using a self-signed cert loaded from a
//     PKCS12 keystore (the app's own identity — same "generate a keystore.p12" idea
//     the platform uses). This is the app channel Dapr talks to.
//   * Acts as a PRODUCER: publishes messages to Apache Pulsar THROUGH the Dapr sidecar
//     via the Dapr pub/sub HTTP API (POST /v1.0/publish/{pubsub}/{topic}). It never
//     speaks Pulsar directly — Dapr (built-in pubsub.pulsar) + a ghostunnel mTLS
//     sidecar do that.
//
// HTTPS routes:
//   GET  /                -> plain text banner
//   GET  /healthz         -> 200 (Dapr app-health probe)
//   GET  /dapr/subscribe  -> [] (this app has no subscriptions; it only produces)
//   POST /publish         -> publish the request body (or an auto-generated message)
//   GET  /publish?count=N -> publish N auto-generated messages
//
// Config (env):
//   DAPR_HTTP            base URL of the Dapr sidecar HTTP API   (default http://localhost:3500)
//   PUBSUB_NAME          Dapr pub/sub component name             (default pulsar-pubsub)
//   TOPIC                Pulsar topic                            (default custom-client-topic)
//   APP_PORT             HTTPS port this app listens on          (default 8443)
//   KEYSTORE_PATH        PKCS12 keystore for the HTTPS cert      (default /certs/app-keystore.p12)
//   KEYSTORE_PASSWORD    keystore password                       (default changeme)
//   RAW_PAYLOAD          publish raw (no CloudEvent envelope)    (default true)
//   PUBLISH_ON_START     auto-publish a batch at startup         (default true)
//   PUBLISH_COUNT        how many to auto-publish                (default 10)
//   PUBLISH_INTERVAL_MS  delay between auto-publishes            (default 1000)

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public class CustomClient {

    // ---- config ----
    static final String DAPR_HTTP   = env("DAPR_HTTP", "http://localhost:3500");
    static final String PUBSUB_NAME = env("PUBSUB_NAME", "pulsar-pubsub");
    static final String TOPIC       = env("TOPIC", "custom-client-topic");
    static final int    APP_PORT    = Integer.parseInt(env("APP_PORT", "8443"));
    static final String KS_PATH     = env("KEYSTORE_PATH", "/certs/app-keystore.p12");
    static final String KS_PASSWORD = env("KEYSTORE_PASSWORD", "changeme");
    static final boolean RAW_PAYLOAD      = Boolean.parseBoolean(env("RAW_PAYLOAD", "true"));
    static final boolean PUBLISH_ON_START = Boolean.parseBoolean(env("PUBLISH_ON_START", "true"));
    static final int    PUBLISH_COUNT     = Integer.parseInt(env("PUBLISH_COUNT", "10"));
    static final long   PUBLISH_INTERVAL  = Long.parseLong(env("PUBLISH_INTERVAL_MS", "1000"));

    static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    static final AtomicInteger SEQ = new AtomicInteger(0);

    public static void main(String[] args) throws Exception {
        log("custom-client starting");
        log("  dapr        = " + DAPR_HTTP);
        log("  pubsub/topic= " + PUBSUB_NAME + " / " + TOPIC);
        log("  https port  = " + APP_PORT + " (keystore " + KS_PATH + ")");

        HttpsServer server = HttpsServer.create(new InetSocketAddress(APP_PORT), 0);
        server.setHttpsConfigurator(new HttpsConfigurator(buildSslContext()));
        server.setExecutor(Executors.newFixedThreadPool(4));
        server.createContext("/", CustomClient::handleRoot);
        server.createContext("/healthz", CustomClient::handleHealthz);
        server.createContext("/dapr/subscribe", CustomClient::handleSubscribe);
        server.createContext("/publish", CustomClient::handlePublish);
        server.start();
        log("HTTPS server up on :" + APP_PORT);

        if (PUBLISH_ON_START) {
            // Publish a batch once the Dapr sidecar is ready. Do it off the main thread
            // so the HTTPS server (which Dapr may probe) is already serving.
            Thread t = new Thread(CustomClient::publishBatch, "startup-publisher");
            t.setDaemon(true);
            t.start();
        }
    }

    // ---------------- Dapr publishing ----------------

    static void publishBatch() {
        if (!waitForDapr(Duration.ofSeconds(60))) {
            log("Dapr sidecar not ready in time; skipping startup batch");
            return;
        }
        log("Dapr ready — publishing " + PUBLISH_COUNT + " message(s) to topic '" + TOPIC + "'");
        int ok = 0;
        for (int i = 0; i < PUBLISH_COUNT; i++) {
            String body = autoMessage();
            if (publish(body)) ok++;
            sleep(PUBLISH_INTERVAL);
        }
        log("startup batch done: " + ok + "/" + PUBLISH_COUNT + " published");
    }

    /** POST the given JSON body to Dapr's publish API. Returns true on 2xx. */
    static boolean publish(String jsonBody) {
        // URL-encode the topic: fully-qualified Pulsar names (persistent://t/ns/topic)
        // contain "//" which daprd's router would otherwise collapse to "/".
        String encodedTopic = java.net.URLEncoder.encode(TOPIC, StandardCharsets.UTF_8);
        String url = DAPR_HTTP + "/v1.0/publish/" + PUBSUB_NAME + "/" + encodedTopic
                + (RAW_PAYLOAD ? "?metadata.rawPayload=true" : "");
        try {
            HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(10))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(jsonBody, StandardCharsets.UTF_8))
                    .build();
            HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
            boolean ok = resp.statusCode() / 100 == 2;
            log((ok ? "PUBLISHED " : "PUBLISH FAILED (" + resp.statusCode() + ") ") + jsonBody
                    + (ok ? "" : " -> " + resp.body()));
            return ok;
        } catch (Exception e) {
            log("PUBLISH ERROR for " + jsonBody + " : " + e.getMessage());
            return false;
        }
    }

    /** Poll the Dapr sidecar's own health endpoint until it reports ready. */
    static boolean waitForDapr(Duration timeout) {
        Instant deadline = Instant.now().plus(timeout);
        String url = DAPR_HTTP + "/v1.0/healthz";
        while (Instant.now().isBefore(deadline)) {
            try {
                HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                        .timeout(Duration.ofSeconds(3)).GET().build();
                int code = HTTP.send(req, HttpResponse.BodyHandlers.discarding()).statusCode();
                if (code / 100 == 2) return true;
            } catch (Exception ignored) {
                // sidecar not up yet
            }
            sleep(1000);
        }
        return false;
    }

    static String autoMessage() {
        int n = SEQ.incrementAndGet();
        return "{\"id\":" + n
                + ",\"source\":\"custom-client\""
                + ",\"topic\":\"" + TOPIC + "\""
                + ",\"ts\":\"" + Instant.now() + "\""
                + ",\"text\":\"hello from custom-client #" + n + "\"}";
    }

    // ---------------- HTTPS handlers ----------------

    static void handleRoot(HttpExchange x) throws IOException {
        respond(x, 200, "custom-client (Dapr producer) — POST /publish or GET /publish?count=N\n");
    }

    static void handleHealthz(HttpExchange x) throws IOException {
        respond(x, 200, "OK");
    }

    // This app only produces; advertise no subscriptions to Dapr.
    static void handleSubscribe(HttpExchange x) throws IOException {
        x.getResponseHeaders().set("Content-Type", "application/json");
        respond(x, 200, "[]");
    }

    static void handlePublish(HttpExchange x) throws IOException {
        try {
            if ("GET".equalsIgnoreCase(x.getRequestMethod())) {
                int count = queryInt(x, "count", 1);
                int ok = 0;
                for (int i = 0; i < count; i++) if (publish(autoMessage())) ok++;
                respond(x, 200, "published " + ok + "/" + count + "\n");
                return;
            }
            if ("POST".equalsIgnoreCase(x.getRequestMethod())) {
                String body = new String(x.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
                if (body.isBlank()) body = autoMessage();
                boolean ok = publish(body);
                respond(x, ok ? 200 : 502, "publish " + (ok ? "ok" : "failed") + "\n");
                return;
            }
            respond(x, 405, "method not allowed\n");
        } catch (Exception e) {
            respond(x, 500, "error: " + e.getMessage() + "\n");
        }
    }

    // ---------------- helpers ----------------

    static SSLContext buildSslContext() throws Exception {
        char[] pw = KS_PASSWORD.toCharArray();
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (InputStream in = new FileInputStream(KS_PATH)) {
            ks.load(in, pw);
        }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, pw);
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(kmf.getKeyManagers(), null, null);
        return ctx;
    }

    static void respond(HttpExchange x, int code, String body) throws IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        x.sendResponseHeaders(code, b.length);
        try (OutputStream os = x.getResponseBody()) {
            os.write(b);
        }
    }

    static int queryInt(HttpExchange x, String key, int dflt) {
        String q = x.getRequestURI().getQuery();
        if (q == null) return dflt;
        for (String p : q.split("&")) {
            int eq = p.indexOf('=');
            if (eq > 0 && p.substring(0, eq).equals(key)) {
                try { return Integer.parseInt(p.substring(eq + 1)); } catch (NumberFormatException e) { return dflt; }
            }
        }
        return dflt;
    }

    static String env(String k, String dflt) {
        String v = System.getenv(k);
        return (v == null || v.isBlank()) ? dflt : v;
    }

    static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    static void log(String msg) {
        System.out.println("[custom-client] " + msg);
    }
}
