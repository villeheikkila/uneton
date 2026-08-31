FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/uneton ./platform/backend/cmd/server

FROM alpine:3.23
RUN addgroup -S app && adduser -S -G app app && mkdir -p /data && chown app:app /data
USER app
COPY --from=build /out/uneton /usr/local/bin/uneton
ENV UNETON_RUNTIME_ENVIRONMENT=production \
    UNETON_DATABASE_PATH=/data/uneton.sqlite \
    UNETON_HTTP_LISTEN_ADDRESS=0.0.0.0:8080 \
    UNETON_LOG_FORMAT=json \
    UNETON_LOG_LEVEL=info \
    UNETON_RUNTIME_SHUTDOWN_TIMEOUT=30s
EXPOSE 8080
ENTRYPOINT ["uneton"]
