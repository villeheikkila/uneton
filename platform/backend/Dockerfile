# syntax=docker/dockerfile:1

# The builder runs natively and cross-compiles, so a multi-architecture release
# never builds Go under emulation.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY internal/gen ./internal/gen
COPY platform/backend ./platform/backend
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/uneton ./platform/backend/cmd/server
RUN mkdir -p /out/data

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
LABEL org.opencontainers.image.title="uneton-backend" \
      org.opencontainers.image.description="Uneton ConnectRPC API and authoritative SQLite store" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"
COPY --from=build --chown=10001:10001 /out/data /data
USER 10001:10001
COPY --from=build /out/uneton /usr/local/bin/uneton
ENV UNETON_RUNTIME_ENVIRONMENT=production \
    UNETON_DATABASE_PATH=/data/uneton.sqlite \
    UNETON_HTTP_LISTEN_ADDRESS=0.0.0.0:8080 \
    UNETON_LOG_FORMAT=json \
    UNETON_LOG_LEVEL=info \
    UNETON_RUNTIME_SHUTDOWN_TIMEOUT=30s
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 CMD ["uneton", "healthcheck"]
ENTRYPOINT ["uneton"]
CMD ["serve"]
