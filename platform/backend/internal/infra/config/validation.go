package config

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// Validate checks the effective configuration independently of its source.
func (cfg Config) Validate() error {
	environment := cfg.Environment
	if environment != Development && environment != Production {
		return errors.New("UNETON_RUNTIME_ENVIRONMENT must be development or production")
	}
	if cfg.LogFormat != "pretty" && cfg.LogFormat != "json" {
		return errors.New("UNETON_LOG_FORMAT must be pretty or json")
	}
	if cfg.ShutdownTimeout <= 0 {
		return errors.New("UNETON_RUNTIME_SHUTDOWN_TIMEOUT must be a positive duration")
	}
	if strings.TrimSpace(cfg.HTTPAddress) == "" || strings.TrimSpace(cfg.DatabasePath) == "" {
		return errors.New("HTTP listen address and database path are required")
	}
	if len(cfg.TokenSecret.Reveal()) < 32 {
		return errors.New("UNETON_AUTH_TOKEN_SECRET must contain at least 32 characters")
	}
	if environment == Production && (cfg.LegalOperator == "" || cfg.LegalEmail == "") {
		return errors.New("UNETON_LEGAL_OPERATOR_NAME and UNETON_LEGAL_CONTACT_EMAIL are required in production")
	}
	if !strings.Contains(cfg.LegalEmail, "@") || strings.ContainsAny(cfg.LegalEmail, " \t\r\n") {
		return errors.New("UNETON_LEGAL_CONTACT_EMAIL must be an email address")
	}
	appleValues := []string{cfg.Apple.ClientID, cfg.Apple.TeamID, cfg.Apple.KeyID, cfg.Apple.PrivateKey.Reveal()}
	configured, complete := false, true
	for _, appleValue := range appleValues {
		configured = configured || strings.TrimSpace(appleValue) != ""
		complete = complete && strings.TrimSpace(appleValue) != ""
	}
	if (configured || environment == Production) && !complete {
		return errors.New("sign in with Apple must be configured completely")
	}
	apnsValues := []string{cfg.APNS.TeamID, cfg.APNS.KeyID, cfg.APNS.PrivateKey.Reveal(), cfg.APNS.Topic}
	apnsConfigured, apnsComplete := false, true
	for _, apnsValue := range apnsValues {
		apnsConfigured = apnsConfigured || strings.TrimSpace(apnsValue) != ""
		apnsComplete = apnsComplete && strings.TrimSpace(apnsValue) != ""
	}
	if apnsConfigured && !apnsComplete {
		return errors.New("APNs must be configured completely")
	}
	if environment == Production && cfg.Apple.ServerNotificationURL == "" {
		return errors.New("UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL is required in production")
	}
	if (cfg.Apple.TokenKeyring.Reveal() == "") != (cfg.Apple.TokenActiveKeyID == "") {
		return errors.New("apple token encryption keyring and active key ID must be configured together")
	}
	if environment == Production && cfg.Apple.TokenKeyring.Reveal() == "" {
		return errors.New("apple token encryption keyring is required in production")
	}
	if raw := cfg.Apple.TokenKeyring.Reveal(); raw != "" {
		var keys map[string]string
		if err := json.Unmarshal([]byte(raw), &keys); err != nil || len(keys) == 0 {
			return errors.New("UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON must be a non-empty JSON object")
		}
		if _, exists := keys[cfg.Apple.TokenActiveKeyID]; !exists {
			return errors.New("active Apple token encryption key is missing from keyring")
		}
		for _, encoded := range keys {
			decoded, decodeErr := base64.StdEncoding.DecodeString(encoded)
			if decodeErr != nil || len(decoded) != 32 {
				return errors.New("apple token encryption keys must be base64-encoded 32-byte values")
			}
		}
	}
	if raw := cfg.Apple.ServerNotificationURL; raw != "" {
		parsed, parseErr := url.Parse(raw)
		if parseErr != nil || !parsed.IsAbs() || parsed.Host == "" || parsed.Path == "" || parsed.RawQuery != "" || parsed.Fragment != "" {
			return errors.New("UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL must be an absolute URL with a path and no query or fragment")
		}
		if environment == Production && parsed.Scheme != "https" {
			return errors.New("UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL must use https in production")
		}
	}
	if environment == Production && (cfg.Apple.TokenURL != "" || cfg.Apple.KeysURL != "" || cfg.Apple.RevokeURL != "") {
		return errors.New("apple endpoint overrides are only allowed in development")
	}
	for name, raw := range map[string]string{"token": cfg.Apple.TokenURL, "JWKS": cfg.Apple.KeysURL, "revoke": cfg.Apple.RevokeURL} {
		if raw == "" {
			continue
		}
		parsed, parseErr := url.Parse(raw)
		if parseErr != nil || !parsed.IsAbs() || parsed.Host == "" {
			return fmt.Errorf("apple %s endpoint override must be an absolute URL", name)
		}
	}
	return nil
}
