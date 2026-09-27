FROM golang:1.27-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY internal/gen ./internal/gen
COPY platform/backend ./platform/backend
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/uneton ./platform/backend/cmd/server
RUN mkdir -p /out/data

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
COPY --from=build --chown=10001:10001 /out/data /data
USER 10001:10001
COPY --from=build /out/uneton /usr/local/bin/uneton
ENV UNETON_RUNTIME_ENVIRONMENT=production \
    UNETON_DATABASE_PATH=/data/uneton.sqlite \
    UNETON_HTTP_LISTEN_ADDRESS=0.0.0.0:8080 \
    UNETON_LOG_FORMAT=json \
    UNETON_LOG_LEVEL=info \
    UNETON_RUNTIME_SHUTDOWN_TIMEOUT=30s
EXPOSE 8080
ENTRYPOINT ["uneton"]
