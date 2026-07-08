# Builds the pluggable Pulsar pub/sub component. pulsar-client-go is pure Go, so we
# build a fully static binary and drop it into a distroless image.
FROM golang:1.22-bookworm AS build
WORKDIR /src
# Dependencies are vendored (./vendor), so the build needs NO network / Go proxy —
# important behind a corporate firewall. GOPROXY=off guarantees no outbound fetch.
ENV GOFLAGS=-mod=vendor GOPROXY=off
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/pulsar-pluggable .

# Alpine (not distroless) so compose can HEALTHCHECK the socket file — daprd must not
# boot until the socket exists. Runs as root so the socket it creates on the shared
# volume is reachable by the daprd sidecar (also root in compose).
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/pulsar-pluggable /pulsar-pluggable
# Default Dapr pluggable sockets dir; must be the SAME volume daprd mounts.
VOLUME ["/tmp/dapr-components-sockets"]
HEALTHCHECK --interval=3s --timeout=2s --retries=20 --start-period=2s \
  CMD test -S /tmp/dapr-components-sockets/pulsar-pluggable.sock || exit 1
ENTRYPOINT ["/pulsar-pluggable"]
