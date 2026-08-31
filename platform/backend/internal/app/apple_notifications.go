package app

import (
	"database/sql"
	"errors"
	"mime"
	"net/http"
	"strings"
)

const appleNotificationMaxBody = 256 << 10

func (s *Server) appleServerNotification(w http.ResponseWriter, r *http.Request) {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/x-www-form-urlencoded" {
		http.Error(w, "unsupported content type", http.StatusUnsupportedMediaType)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, appleNotificationMaxBody)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid notification", http.StatusBadRequest)
		return
	}
	payload := strings.TrimSpace(r.PostForm.Get("payload"))
	if payload == "" {
		http.Error(w, "missing payload", http.StatusBadRequest)
		return
	}
	notification, err := s.apple.verifyServerNotification(payload)
	if err != nil {
		http.Error(w, "invalid notification", http.StatusBadRequest)
		return
	}

	if notification.Type == "consent-revoked" || notification.Type == "account-deleted" {
		userID, lookupErr := s.store.Queries.UserIDByAppleSubject(r.Context(), notification.Subject)
		if lookupErr != nil && !errors.Is(lookupErr, sql.ErrNoRows) {
			s.logger.ErrorContext(r.Context(), "could not resolve Apple notification subject", "error", lookupErr)
			http.Error(w, "notification processing failed", http.StatusInternalServerError)
			return
		}
		if lookupErr == nil {
			if err := s.eraseAccount(r.Context(), userID); err != nil {
				s.logger.ErrorContext(r.Context(), "could not erase account after Apple notification", "error", err)
				http.Error(w, "notification processing failed", http.StatusInternalServerError)
				return
			}
		}
	}
	s.logger.InfoContext(r.Context(), "processed Apple server notification", "notification_id", notification.ID, "event_type", notification.Type)
	w.WriteHeader(http.StatusOK)
}
