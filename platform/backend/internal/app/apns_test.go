package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestLiveActivityStartRequest(t *testing.T) {
	now := time.Date(2026, 8, 31, 7, 0, 0, 0, time.UTC)
	var payload map[string]any
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/3/device/push-token" {
			t.Errorf("path = %s", request.URL.Path)
		}
		if request.Header.Get("apns-push-type") != "liveactivity" {
			t.Errorf("push type = %s", request.Header.Get("apns-push-type"))
		}
		if request.Header.Get("apns-topic") != "solutions.bytesized.uneton.push-type.liveactivity" {
			t.Errorf("topic = %s", request.Header.Get("apns-topic"))
		}
		if request.Header.Get("authorization") == "" {
			t.Error("missing provider authorization")
		}
		if request.Header.Get("apns-expiration") != "1788246000" {
			t.Errorf("expiration = %s", request.Header.Get("apns-expiration"))
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}

	provider := NewAPNSProvider(APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t), Topic: "solutions.bytesized.uneton"})
	provider.client = client
	provider.now = func() time.Time { return now }
	provider.endpoint = func(string) string { return "https://apns.test" }
	invalid, err := provider.liveActivity(context.Background(), "push-token", "development", "start", map[string]any{"sessionID": "session"}, map[string]any{}, "sleep-session")
	if err != nil || invalid {
		t.Fatalf("invalid = %v, error = %v", invalid, err)
	}
	aps := payload["aps"].(map[string]any)
	if aps["event"] != "start" || aps["attributes-type"] != "SleepActivityAttributes" || aps["input-push-token"] != float64(1) {
		t.Fatalf("aps = %#v", aps)
	}
}

func TestAPNSInvalidTokenResponse(t *testing.T) {
	provider := NewAPNSProvider(APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t), Topic: "solutions.bytesized.uneton"})
	provider.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusGone, Body: io.NopCloser(strings.NewReader(`{"reason":"Unregistered"}`))}, nil
	})}
	provider.endpoint = func(string) string { return "https://apns.test" }
	invalid, err := provider.alert(context.Background(), "push-token", "production", "title", "body", "collapse")
	if err == nil || !invalid {
		t.Fatalf("invalid = %v, error = %v", invalid, err)
	}
}

func TestBackgroundRequestIsSilentAndLowPriority(t *testing.T) {
	var payload map[string]any
	provider := NewAPNSProvider(APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t), Topic: "solutions.bytesized.uneton"})
	provider.client = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("apns-push-type") != "background" || request.Header.Get("apns-priority") != "5" {
			t.Fatalf("headers = %#v", request.Header)
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	provider.endpoint = func(string) string { return "https://apns.test" }
	if invalid, err := provider.background(context.Background(), "push-token", "production", "family-id"); err != nil || invalid {
		t.Fatalf("invalid = %v, error = %v", invalid, err)
	}
	aps := payload["aps"].(map[string]any)
	if len(aps) != 1 || aps["content-available"] != float64(1) || payload["familyID"] != "family-id" {
		t.Fatalf("payload = %#v", payload)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func TestAPNSTransportErrorsDoNotExposeTokens(t *testing.T) {
	failure := errors.New("connection lost")
	provider := NewAPNSProvider(APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t), Topic: "solutions.bytesized.uneton"})
	provider.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, failure })}
	provider.endpoint = func(string) string { return "https://apns.test" }
	_, err := provider.alert(context.Background(), "private-push-token", "development", "title", "body", "id")
	if err == nil || strings.Contains(err.Error(), "private-push-token") || !errors.Is(err, failure) {
		t.Fatalf("transport error must preserve cause without token URL: %v", err)
	}
}

func TestAPNSConfigValidation(t *testing.T) {
	for _, test := range []struct {
		name   string
		config APNSConfig
		valid  bool
	}{
		{name: "disabled", valid: true},
		{name: "partial", config: APNSConfig{Topic: "solutions.bytesized.uneton"}},
		{name: "malformed", config: APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: "invalid", Topic: "solutions.bytesized.uneton"}},
		{name: "valid", config: APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t), Topic: "solutions.bytesized.uneton"}, valid: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := test.config.Validate(); (err == nil) != test.valid {
				t.Fatalf("validation = %v, want valid %t", err, test.valid)
			}
		})
	}
}
