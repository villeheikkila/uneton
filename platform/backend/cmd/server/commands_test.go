package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthcheck(t *testing.T) {
	status := http.StatusOK
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/health/ready" {
			t.Errorf("unexpected path %q", request.URL.Path)
		}
		writer.WriteHeader(status)
	}))
	defer server.Close()
	t.Setenv("UNETON_HTTP_LISTEN_ADDRESS", strings.TrimPrefix(server.URL, "http://"))
	if err := run(context.Background(), io.Discard, io.Discard, []string{"healthcheck"}); err != nil {
		t.Fatalf("healthy server: %v", err)
	}
	status = http.StatusServiceUnavailable
	if err := run(context.Background(), io.Discard, io.Discard, []string{"healthcheck"}); err == nil {
		t.Fatal("unready server should fail healthcheck")
	}
}
