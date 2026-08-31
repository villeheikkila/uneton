package config

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/common/secret"
)

type Environment string

const (
	Development Environment = "development"
	Production  Environment = "production"
)

type Config struct {
	Environment     Environment
	HTTPAddress     string
	DatabasePath    string
	TokenSecret     secret.Value
	LogFormat       string
	LogLevel        slog.Level
	ShutdownTimeout time.Duration
	Apple           AppleConfig
	APNS            APNSConfig
}

type AppleConfig struct {
	ClientID              string
	TeamID                string
	KeyID                 string
	PrivateKey            secret.Value
	ServerNotificationURL string
	TokenURL              string
	KeysURL               string
	RevokeURL             string
	TokenKeyring          secret.Value
	TokenActiveKeyID      string
}

type APNSConfig struct {
	TeamID     string
	KeyID      string
	PrivateKey secret.Value
	Topic      string
}

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
	for key := range values {
		if strings.HasPrefix(key, "UNETON_") && !knownEnvironment[key] {
			return Config{}, fmt.Errorf("unknown environment variable %s", key)
		}
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
	if logFormat != "pretty" && logFormat != "json" {
		return Config{}, errors.New("UNETON_LOG_FORMAT must be pretty or json")
	}
	shutdownTimeout, err := time.ParseDuration(value(values, "UNETON_RUNTIME_SHUTDOWN_TIMEOUT", "10s"))
	if err != nil || shutdownTimeout <= 0 {
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
	if len(cfg.TokenSecret.Reveal()) < 32 {
		return Config{}, errors.New("UNETON_AUTH_TOKEN_SECRET must contain at least 32 characters")
	}
	appleValues := []string{cfg.Apple.ClientID, cfg.Apple.TeamID, cfg.Apple.KeyID, cfg.Apple.PrivateKey.Reveal()}
	configured, complete := false, true
	for _, appleValue := range appleValues {
		configured = configured || strings.TrimSpace(appleValue) != ""
		complete = complete && strings.TrimSpace(appleValue) != ""
	}
	if (configured || environment == Production) && !complete {
		return Config{}, errors.New("sign in with Apple must be configured completely")
	}
	apnsValues := []string{cfg.APNS.TeamID, cfg.APNS.KeyID, cfg.APNS.PrivateKey.Reveal(), cfg.APNS.Topic}
	apnsConfigured, apnsComplete := false, true
	for _, apnsValue := range apnsValues {
		apnsConfigured = apnsConfigured || strings.TrimSpace(apnsValue) != ""
		apnsComplete = apnsComplete && strings.TrimSpace(apnsValue) != ""
	}
	if apnsConfigured && !apnsComplete {
		return Config{}, errors.New("APNs must be configured completely")
	}
	if environment == Production && cfg.Apple.ServerNotificationURL == "" {
		return Config{}, errors.New("UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL is required in production")
	}
	if (cfg.Apple.TokenKeyring.Reveal() == "") != (cfg.Apple.TokenActiveKeyID == "") {
		return Config{}, errors.New("apple token encryption keyring and active key ID must be configured together")
	}
	if environment == Production && cfg.Apple.TokenKeyring.Reveal() == "" {
		return Config{}, errors.New("apple token encryption keyring is required in production")
	}
	if raw := cfg.Apple.TokenKeyring.Reveal(); raw != "" {
		var keys map[string]string
		if err := json.Unmarshal([]byte(raw), &keys); err != nil || len(keys) == 0 {
			return Config{}, errors.New("UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON must be a non-empty JSON object")
		}
		if _, exists := keys[cfg.Apple.TokenActiveKeyID]; !exists {
			return Config{}, errors.New("active Apple token encryption key is missing from keyring")
		}
		for _, encoded := range keys {
			decoded, decodeErr := base64.StdEncoding.DecodeString(encoded)
			if decodeErr != nil || len(decoded) != 32 {
				return Config{}, errors.New("apple token encryption keys must be base64-encoded 32-byte values")
			}
		}
	}
	if raw := cfg.Apple.ServerNotificationURL; raw != "" {
		parsed, parseErr := url.Parse(raw)
		if parseErr != nil || !parsed.IsAbs() || parsed.Host == "" || parsed.Path == "" || parsed.RawQuery != "" || parsed.Fragment != "" {
			return Config{}, errors.New("UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL must be an absolute URL with a path and no query or fragment")
		}
		if environment == Production && parsed.Scheme != "https" {
			return Config{}, errors.New("UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL must use https in production")
		}
	}
	if environment == Production && (cfg.Apple.TokenURL != "" || cfg.Apple.KeysURL != "" || cfg.Apple.RevokeURL != "") {
		return Config{}, errors.New("apple endpoint overrides are only allowed in development")
	}
	for name, raw := range map[string]string{"token": cfg.Apple.TokenURL, "JWKS": cfg.Apple.KeysURL, "revoke": cfg.Apple.RevokeURL} {
		if raw == "" {
			continue
		}
		parsed, parseErr := url.Parse(raw)
		if parseErr != nil || !parsed.IsAbs() || parsed.Host == "" {
			return Config{}, fmt.Errorf("apple %s endpoint override must be an absolute URL", name)
		}
	}
	return cfg, nil
}

func (c Config) WriteRedacted(w io.Writer) error {
	settings := []string{
		"UNETON_AUTH_APPLE_CLIENT_ID=" + c.Apple.ClientID,
		"UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL=" + c.Apple.ServerNotificationURL,
		"UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID=" + c.Apple.TokenActiveKeyID,
		"UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON=***",
		"UNETON_AUTH_TOKEN_SECRET=***",
		"UNETON_INTEGRATION_APNS_TOPIC=" + c.APNS.Topic,
		"UNETON_DATABASE_PATH=" + c.DatabasePath,
		"UNETON_HTTP_LISTEN_ADDRESS=" + c.HTTPAddress,
		"UNETON_LOG_FORMAT=" + c.LogFormat,
		"UNETON_LOG_LEVEL=" + c.LogLevel.String(),
		"UNETON_RUNTIME_ENVIRONMENT=" + string(c.Environment),
		"UNETON_RUNTIME_SHUTDOWN_TIMEOUT=" + c.ShutdownTimeout.String(),
	}
	sort.Strings(settings)
	for _, setting := range settings {
		if _, err := fmt.Fprintln(w, setting); err != nil {
			return err
		}
	}
	return nil
}

func value(values map[string]string, key, fallback string) string {
	if candidate := strings.TrimSpace(values[key]); candidate != "" {
		return candidate
	}
	return fallback
}

var knownEnvironment = map[string]bool{
	"UNETON_RUNTIME_ENVIRONMENT":                       true,
	"UNETON_HTTP_LISTEN_ADDRESS":                       true,
	"UNETON_DATABASE_PATH":                             true,
	"UNETON_AUTH_TOKEN_SECRET":                         true,
	"UNETON_LOG_FORMAT":                                true,
	"UNETON_LOG_LEVEL":                                 true,
	"UNETON_RUNTIME_SHUTDOWN_TIMEOUT":                  true,
	"UNETON_AUTH_APPLE_CLIENT_ID":                      true,
	"UNETON_INTEGRATION_APPLE_TEAM_ID":                 true,
	"UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID":          true,
	"UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM":         true,
	"UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL":        true,
	"UNETON_INTEGRATION_APPLE_TOKEN_URL":               true,
	"UNETON_INTEGRATION_APPLE_JWKS_URL":                true,
	"UNETON_INTEGRATION_APPLE_REVOKE_URL":              true,
	"UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON":  true,
	"UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID": true,
	"UNETON_INTEGRATION_APNS_TEAM_ID":                  true,
	"UNETON_INTEGRATION_APNS_PRIVATE_KEY_ID":           true,
	"UNETON_INTEGRATION_APNS_PRIVATE_KEY_PEM":          true,
	"UNETON_INTEGRATION_APNS_TOPIC":                    true,
}
