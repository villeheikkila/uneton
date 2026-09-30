package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strings"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/common/secret"
)

func CurrentEnv() map[string]string {
	values := make(map[string]string)
	for _, item := range os.Environ() {
		key, value, ok := strings.Cut(item, "=")
		if ok {
			values[key] = value
		}
	}
	return values
}

func FromEnv(values map[string]string) (Config, error) {
	unknown := make([]string, 0)
	for key := range values {
		if strings.HasPrefix(key, "UNETON_") && !knownEnvironment[key] {
			unknown = append(unknown, key)
		}
	}
	sort.Strings(unknown)
	if len(unknown) > 0 {
		return Config{}, fmt.Errorf("unknown environment variables: %s", strings.Join(unknown, ", "))
	}
	environment := Environment(strings.ToLower(strings.TrimSpace(values["UNETON_RUNTIME_ENVIRONMENT"])))
	if environment != Development && environment != Production {
		return Config{}, errors.New("UNETON_RUNTIME_ENVIRONMENT must be development or production")
	}
	level := new(slog.LevelVar)
	if err := level.UnmarshalText([]byte(value(values, "UNETON_LOG_LEVEL", "info"))); err != nil {
		return Config{}, fmt.Errorf("UNETON_LOG_LEVEL: %w", err)
	}
	logFormat := value(values, "UNETON_LOG_FORMAT", map[bool]string{true: "pretty", false: "json"}[environment == Development])
	shutdownTimeout, err := time.ParseDuration(value(values, "UNETON_RUNTIME_SHUTDOWN_TIMEOUT", "10s"))
	if err != nil {
		return Config{}, errors.New("UNETON_RUNTIME_SHUTDOWN_TIMEOUT must be a positive duration")
	}
	cfg := Config{
		Environment:     environment,
		HTTPAddress:     value(values, "UNETON_HTTP_LISTEN_ADDRESS", "127.0.0.1:8080"),
		DatabasePath:    value(values, "UNETON_DATABASE_PATH", "platform/backend/var/uneton.sqlite"),
		TokenSecret:     secret.New(values["UNETON_AUTH_TOKEN_SECRET"]),
		LogFormat:       logFormat,
		LogLevel:        level.Level(),
		ShutdownTimeout: shutdownTimeout,
		LegalOperator:   value(values, "UNETON_LEGAL_OPERATOR_NAME", "Uneton"),
		LegalEmail:      value(values, "UNETON_LEGAL_CONTACT_EMAIL", "support@example.invalid"),
		Apple: AppleConfig{
			ClientID:              strings.TrimSpace(values["UNETON_AUTH_APPLE_CLIENT_ID"]),
			TeamID:                strings.TrimSpace(values["UNETON_INTEGRATION_APPLE_TEAM_ID"]),
			KeyID:                 strings.TrimSpace(values["UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID"]),
			PrivateKey:            secret.New(values["UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM"]),
			ServerNotificationURL: strings.TrimSpace(values["UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL"]),
			TokenURL:              strings.TrimSpace(values["UNETON_INTEGRATION_APPLE_TOKEN_URL"]),
			KeysURL:               strings.TrimSpace(values["UNETON_INTEGRATION_APPLE_JWKS_URL"]),
			RevokeURL:             strings.TrimSpace(values["UNETON_INTEGRATION_APPLE_REVOKE_URL"]),
			TokenKeyring:          secret.New(values["UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON"]),
			TokenActiveKeyID:      strings.TrimSpace(values["UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID"]),
		},
		APNS: APNSConfig{
			TeamID:     strings.TrimSpace(values["UNETON_INTEGRATION_APNS_TEAM_ID"]),
			KeyID:      strings.TrimSpace(values["UNETON_INTEGRATION_APNS_PRIVATE_KEY_ID"]),
			PrivateKey: secret.New(values["UNETON_INTEGRATION_APNS_PRIVATE_KEY_PEM"]),
			Topic:      strings.TrimSpace(values["UNETON_INTEGRATION_APNS_TOPIC"]),
		},
	}
	if cfg.APNS.TeamID == "" && cfg.APNS.KeyID == "" && cfg.APNS.PrivateKey.Reveal() == "" && cfg.APNS.Topic == "" {
		cfg.APNS = APNSConfig{TeamID: cfg.Apple.TeamID, KeyID: cfg.Apple.KeyID, PrivateKey: cfg.Apple.PrivateKey, Topic: cfg.Apple.ClientID}
	}
	if environment == Production {
		cfg.LegalOperator = strings.TrimSpace(values["UNETON_LEGAL_OPERATOR_NAME"])
		cfg.LegalEmail = strings.TrimSpace(values["UNETON_LEGAL_CONTACT_EMAIL"])
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func value(values map[string]string, key, fallback string) string {
	if candidate := strings.TrimSpace(values[key]); candidate != "" {
		return candidate
	}
	return fallback
}
