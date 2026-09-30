package app

import (
	_ "embed"
	"html/template"
	"net/http"
	"regexp"
)

//go:embed invitation.html
var invitationHTML string

var invitationTemplate = template.Must(template.New("invitation").Parse(invitationHTML))
var invitationTokenPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func (s *Server) appleAppSiteAssociation(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// Keep this application identifier aligned with clients/ios/project.yml.
	writeJSON(w, http.StatusOK, map[string]any{
		"applinks": map[string]any{
			"apps": []string{},
			"details": []map[string]any{{
				"appID": "J9S7QG9SVR.solutions.bytesized.uneton",
				"paths": []string{"/invite/*"},
			}},
		},
	})
}

func (s *Server) invitationPage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow, noarchive")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	token := r.PathValue("token")
	if !invitationTokenPattern.MatchString(token) {
		http.NotFound(w, r)
		return
	}
	// Rendering never looks up or claims a token. Only authenticated AcceptInvite
	// can validate expiry/revocation, add membership, and claim the invitation.
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = invitationTemplate.Execute(w, struct {
		Finnish bool
		Token   string
	}{Finnish: r.URL.Query().Get("lang") == "fi", Token: token})
}
