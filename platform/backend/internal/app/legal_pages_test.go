package app

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicLegalPages(t *testing.T) {
	handler := NewServer(Config{
		TokenSecret:       []byte("test-secret-that-is-at-least-thirty-two-bytes"),
		LegalOperator:     "Example Operator",
		LegalContactEmail: "privacy@example.invalid",
	}).Handler()
	for _, test := range []struct {
		path string
		text string
	}{
		{path: "/privacy", text: "child nickname and birth date"},
		{path: "/privacy?lang=fi", text: "lapsen kutsumanimen"},
		{path: "/terms", text: "informational estimates"},
		{path: "/terms?lang=fi", text: "suuntaa-antavia arvioita"},
		{path: "/support", text: "For help with Uneton"},
		{path: "/support?lang=fi", text: "Unetonin käyttöön"},
	} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, test.path, nil))
		if recorder.Code != http.StatusOK {
			t.Errorf("GET %s status = %d", test.path, recorder.Code)
		}
		if !strings.HasPrefix(recorder.Header().Get("Content-Type"), "text/html") || !strings.Contains(recorder.Body.String(), test.text) {
			t.Errorf("GET %s did not serve the expected legal page", test.path)
		}
		if !strings.Contains(recorder.Body.String(), "privacy@example.invalid") || strings.Contains(recorder.Body.String(), "{{") {
			t.Errorf("GET %s did not render the configured contact", test.path)
		}
	}
}
