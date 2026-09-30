package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestInvitationAssociation(t *testing.T) {
	handler := NewServer(Config{}).Handler()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/.well-known/apple-app-site-association", nil))
	var association struct {
		Applinks struct {
			Details []struct {
				AppID string   `json:"appID"`
				Paths []string `json:"paths"`
			} `json:"details"`
		} `json:"applinks"`
	}
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("association response: %d %s", response.Code, response.Body.String())
	}
	if err := json.Unmarshal(response.Body.Bytes(), &association); err != nil {
		t.Fatal(err)
	}
	if len(association.Applinks.Details) != 1 {
		t.Fatalf("unexpected association: %+v", association)
	}
	detail := association.Applinks.Details[0]
	if detail.AppID != "J9S7QG9SVR.solutions.bytesized.uneton" || len(detail.Paths) != 1 || detail.Paths[0] != "/invite/*" {
		t.Fatalf("unexpected app identity or paths: %+v", detail)
	}
}

func TestInvitationLandingPage(t *testing.T) {
	// No database is configured: previews must not read or mutate family state.
	handler := NewServer(Config{}).Handler()
	for _, test := range []struct {
		query string
		text  string
	}{
		{query: "", text: "Open in Uneton"},
		{query: "?lang=fi", text: "Avaa Unetonissa"},
	} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/invite/opaque-token_123"+test.query, nil))
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), test.text) ||
			!strings.Contains(response.Body.String(), `href="uneton://invite/opaque-token_123"`) {
			t.Fatalf("invitation response: %d %s", response.Code, response.Body.String())
		}
		for header, want := range map[string]string{
			"Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
			"X-Robots-Tag": "noindex, nofollow, noarchive", "X-Content-Type-Options": "nosniff",
		} {
			if response.Header().Get(header) != want {
				t.Errorf("%s = %q", header, response.Header().Get(header))
			}
		}
		if response.Header().Get("Content-Security-Policy") == "" || strings.Contains(response.Body.String(), "<script") {
			t.Error("invitation page must restrict resources and use no scripts")
		}
	}
}

func TestMalformedInvitationPaths(t *testing.T) {
	handler := NewServer(Config{}).Handler()
	for _, path := range []string{"/invite/", "/invite/token/extra", "/invite/token%2Fextra", "/invite/%3Cscript%3E", "/invite/" + strings.Repeat("a", 129)} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusNotFound {
			t.Errorf("malformed invitation returned %d", response.Code)
		}
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/invite/token", nil))
	if response.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST invitation status = %d", response.Code)
	}
}
