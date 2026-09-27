package app

import (
	"net/http"

	"solutions.bytesized/uneton/platform/backend/internal/legal"
)

func (s *Server) legalPage(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		page, err := legal.Page(name, r.URL.Query().Get("lang"), legal.Details{
			Operator: s.legalOperator,
			Email:    s.legalContactEmail,
		})
		if err != nil {
			http.Error(w, "legal page unavailable", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=3600")
		_, _ = w.Write(page)
	}
}
