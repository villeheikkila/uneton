package app

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	"connectrpc.com/connect"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
	"solutions.bytesized/uneton/platform/backend/internal/transport/connectapi"
)

type Config struct {
	Store                  *store.Store
	TokenSecret            []byte
	Development            bool
	Logger                 *slog.Logger
	Now                    func() time.Time
	Apple                  AppleConfig
	APNS                   APNSConfig
	StreamHeartbeat        time.Duration
	StreamLifetime         time.Duration
	SnapshotEventThreshold int
	DeliveryRetention      time.Duration
}

type Server struct {
	store                  *store.Store
	tokenSecret            []byte
	development            bool
	logger                 *slog.Logger
	now                    func() time.Time
	broker                 *broker
	mux                    *http.ServeMux
	apple                  *AppleAuthenticator
	apns                   *APNSProvider
	appleTokenKeys         *appleTokenKeyring
	streamHeartbeat        time.Duration
	streamLifetime         time.Duration
	snapshotEventThreshold int
	deliveryRetention      time.Duration
	readiness              atomic.Bool
}

func NewServer(config Config) *Server {
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.StreamHeartbeat <= 0 {
		config.StreamHeartbeat = 25 * time.Second
	}
	if config.StreamLifetime <= 0 {
		config.StreamLifetime = 5 * time.Minute
	}
	if config.SnapshotEventThreshold <= 0 {
		config.SnapshotEventThreshold = 10_000
	}
	if config.DeliveryRetention <= 0 {
		config.DeliveryRetention = 7 * 24 * time.Hour
	}
	s := &Server{
		store: config.Store, tokenSecret: config.TokenSecret, development: config.Development,
		logger: config.Logger, now: config.Now, broker: newBroker(), mux: http.NewServeMux(),
		streamHeartbeat: config.StreamHeartbeat, streamLifetime: config.StreamLifetime,
		snapshotEventThreshold: config.SnapshotEventThreshold, deliveryRetention: config.DeliveryRetention,
	}
	tokenKeys, err := newAppleTokenKeyring(config.Apple.TokenKeyring, config.Apple.TokenActiveKeyID, config.TokenSecret)
	if err != nil {
		config.Logger.Error("invalid Apple token encryption keyring", "error", err)
	} else {
		s.appleTokenKeys = tokenKeys
	}
	if config.Apple.configured() {
		s.apple = NewAppleAuthenticator(config.Apple)
	}
	s.apns = NewAPNSProvider(config.APNS)
	s.routes()
	s.readiness.Store(true)
	return s
}

func (s *Server) Handler() http.Handler { return s.recoverAndLog(s.mux) }

func (s *Server) MarkNotReady() { s.readiness.Store(false) }

// RewrapAppleTokens migrates provider credentials to the active encryption key.
// It is safe to run at every startup and fails closed if a referenced old key
// has been removed before all ciphertext was migrated.
func (s *Server) RewrapAppleTokens(ctx context.Context) error {
	rows, err := s.store.Queries.AppleRefreshTokens(ctx)
	if err != nil {
		return fmt.Errorf("list Apple refresh tokens: %w", err)
	}
	for _, row := range rows {
		token, needsRewrap, err := s.appleTokenKeys.open(row.AppleRefreshTokenCiphertext)
		if err != nil {
			return fmt.Errorf("open Apple refresh token for user %s: %w", row.ID, err)
		}
		if !needsRewrap {
			continue
		}
		ciphertext, err := s.appleTokenKeys.seal(token)
		if err != nil {
			return fmt.Errorf("rewrap Apple refresh token for user %s: %w", row.ID, err)
		}
		if err := s.store.Queries.UpdateAppleRefreshToken(ctx, storedb.UpdateAppleRefreshTokenParams{AppleRefreshTokenCiphertext: ciphertext, ID: row.ID}); err != nil {
			return fmt.Errorf("store rewrapped Apple refresh token for user %s: %w", row.ID, err)
		}
	}
	return nil
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	s.mux.HandleFunc("GET /health/ready", s.ready)
	if s.apple != nil && strings.TrimSpace(s.apple.config.ServerNotificationURL) != "" {
		parsed, _ := url.Parse(s.apple.config.ServerNotificationURL)
		s.mux.HandleFunc("POST "+parsed.Path, s.appleServerNotification)
	}
	path, handler := unetonv1connect.NewUnetonServiceHandler(
		s,
		connect.WithReadMaxBytes(1<<20),
		connect.WithInterceptors(connectapi.NewPolicyInterceptor(s.authenticateConnectRequest, s.development)),
	)
	s.mux.Handle(path, handler)
}

type principalContextKey struct{}

func (s *Server) authenticateConnectRequest(ctx context.Context, header http.Header) (context.Context, error) {
	p, err := s.authenticatePrincipal(ctx, header)
	if err != nil {
		return ctx, err
	}
	return context.WithValue(ctx, principalContextKey{}, p), nil
}

func (s *Server) authenticatePrincipal(ctx context.Context, header http.Header) (principal, error) {
	p, err := s.principal(ctx, header.Get("Authorization"))
	if err != nil {
		return principal{}, connect.NewError(connect.CodeUnauthenticated, err)
	}
	active, err := s.store.Queries.ActiveDeviceSession(ctx, storedb.ActiveDeviceSessionParams{ID: p.DeviceID, UserID: p.UserID})
	if err != nil || !active {
		return principal{}, connect.NewError(connect.CodeUnauthenticated, errors.New("session has been revoked"))
	}
	return p, nil
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	if !s.readiness.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "server is draining"})
		return
	}
	if err := s.store.DB.PingContext(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "database unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) principal(ctx context.Context, authorization string) (principal, error) {
	if !strings.HasPrefix(authorization, "Bearer ") {
		return principal{}, errors.New("authorization required")
	}
	return verifyToken(s.tokenSecret, strings.TrimPrefix(authorization, "Bearer "), s.now())
}

func (s *Server) isMember(ctx context.Context, familyID, userID string) bool {
	value, err := s.store.Queries.IsFamilyMember(ctx, storedb.IsFamilyMemberParams{FamilyID: familyID, UserID: userID})
	return err == nil && value
}

func (s *Server) hasRole(ctx context.Context, familyID, userID, role string) bool {
	value, err := s.store.Queries.HasFamilyRole(ctx, storedb.HasFamilyRoleParams{FamilyID: familyID, UserID: userID, Role: role})
	return err == nil && value
}

func (s *Server) recoverAndLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				s.logger.Error("request panic", "error", recovered, "method", r.Method, "path", r.URL.Path)
				http.Error(w, "internal server error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func randomToken() string {
	bytes := make([]byte, 32)
	_, _ = rand.Read(bytes)
	return base64.RawURLEncoding.EncodeToString(bytes)
}

func formatTime(value time.Time) string         { return value.UTC().Format(time.RFC3339Nano) }
func parseTime(value string) (time.Time, error) { return time.Parse(time.RFC3339Nano, value) }

func boundedLimit(value int) int {
	if value <= 0 {
		return 500
	}
	if value > 1000 {
		return 1000
	}
	return value
}

func nullableString(value *time.Time) sql.NullString {
	if value == nil {
		return sql.NullString{}
	}
	return sql.NullString{String: formatTime(*value), Valid: true}
}

func nullableInt(value *int) sql.NullInt64 {
	if value == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: int64(*value), Valid: true}
}

func nullableBool(value *bool) sql.NullInt64 {
	if value == nil {
		return sql.NullInt64{}
	}
	if *value {
		return sql.NullInt64{Int64: 1, Valid: true}
	}
	return sql.NullInt64{Int64: 0, Valid: true}
}

func authenticateRefresh(storedHash []byte, storedExpiry sql.NullString, supplied string, now time.Time) bool {
	expiresAt, err := parseTime(storedExpiry.String)
	return err == nil && storedExpiry.Valid && expiresAt.After(now) && hmac.Equal(storedHash, hashToken(supplied))
}
