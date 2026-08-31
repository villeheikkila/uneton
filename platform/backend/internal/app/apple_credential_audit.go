package app

import (
	"context"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func (s *Server) RunAppleCredentialAudit(ctx context.Context, interval time.Duration) {
	if s.apple == nil || s.appleTokenKeys == nil {
		return
	}
	if interval <= 0 {
		interval = 24 * time.Hour
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		s.auditAppleCredentials(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Server) auditAppleCredentials(ctx context.Context) {
	rows, err := s.store.Queries.AppleRefreshTokens(ctx)
	if err != nil {
		s.logger.ErrorContext(ctx, "could not list Apple credentials for audit", "error", err)
		return
	}
	for _, row := range rows {
		if ctx.Err() != nil {
			return
		}
		refreshToken, _, err := s.appleTokenKeys.open(row.AppleRefreshTokenCiphertext)
		if err != nil {
			s.logger.ErrorContext(ctx, "could not decrypt Apple credential for audit", "user_id", row.ID, "error", err)
			continue
		}
		replacement, invalidGrant, err := s.apple.refreshCredential(ctx, refreshToken)
		if err != nil {
			s.logger.WarnContext(ctx, "Apple credential audit was inconclusive", "user_id", row.ID, "error", err)
			continue
		}
		if invalidGrant {
			if err := s.eraseAccount(ctx, row.ID); err != nil {
				s.logger.ErrorContext(ctx, "could not erase account after Apple invalid_grant", "user_id", row.ID, "error", err)
			}
			continue
		}
		if replacement == "" || replacement == refreshToken {
			continue
		}
		ciphertext, err := s.appleTokenKeys.seal(replacement)
		if err != nil {
			s.logger.ErrorContext(ctx, "could not encrypt rotated Apple credential", "user_id", row.ID, "error", err)
			continue
		}
		if err := s.store.Queries.UpdateAppleRefreshToken(ctx, storedb.UpdateAppleRefreshTokenParams{ID: row.ID, AppleRefreshTokenCiphertext: ciphertext}); err != nil {
			s.logger.ErrorContext(ctx, "could not store rotated Apple credential", "user_id", row.ID, "error", err)
		}
	}
}
