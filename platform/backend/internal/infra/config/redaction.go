package config

import (
	"fmt"
	"io"
	"log/slog"
	"sort"
)

// redactedSettings enumerates the entire environment contract without revealing secrets.
func (c Config) redactedSettings() map[string]string {
	return map[string]string{
		"UNETON_RUNTIME_ENVIRONMENT":                       string(c.Environment),
		"UNETON_HTTP_LISTEN_ADDRESS":                       c.HTTPAddress,
		"UNETON_DATABASE_PATH":                             c.DatabasePath,
		"UNETON_AUTH_TOKEN_SECRET":                         "***",
		"UNETON_LOG_FORMAT":                                c.LogFormat,
		"UNETON_LOG_LEVEL":                                 c.LogLevel.String(),
		"UNETON_RUNTIME_SHUTDOWN_TIMEOUT":                  c.ShutdownTimeout.String(),
		"UNETON_AUTH_APPLE_CLIENT_ID":                      c.Apple.ClientID,
		"UNETON_INTEGRATION_APPLE_TEAM_ID":                 c.Apple.TeamID,
		"UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID":          c.Apple.KeyID,
		"UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM":         "***",
		"UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL":        c.Apple.ServerNotificationURL,
		"UNETON_INTEGRATION_APPLE_TOKEN_URL":               c.Apple.TokenURL,
		"UNETON_INTEGRATION_APPLE_JWKS_URL":                c.Apple.KeysURL,
		"UNETON_INTEGRATION_APPLE_REVOKE_URL":              c.Apple.RevokeURL,
		"UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON":  "***",
		"UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID": c.Apple.TokenActiveKeyID,
		"UNETON_INTEGRATION_APNS_TEAM_ID":                  c.APNS.TeamID,
		"UNETON_INTEGRATION_APNS_PRIVATE_KEY_ID":           c.APNS.KeyID,
		"UNETON_INTEGRATION_APNS_PRIVATE_KEY_PEM":          "***",
		"UNETON_INTEGRATION_APNS_TOPIC":                    c.APNS.Topic,
		"UNETON_LEGAL_OPERATOR_NAME":                       "***",
		"UNETON_LEGAL_CONTACT_EMAIL":                       "***",
	}
}

func (c Config) WriteRedacted(w io.Writer) error {
	settings := c.redactedSettings()
	names := make([]string, 0, len(settings))
	for name := range settings {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if _, err := fmt.Fprintf(w, "%s=%s\n", name, settings[name]); err != nil {
			return err
		}
	}
	return nil
}

// RedactedLogValue uses the same secret-safe representation as the config command.
func (c Config) RedactedLogValue() slog.Value {
	settings := c.redactedSettings()
	names := make([]string, 0, len(settings))
	for name := range settings {
		names = append(names, name)
	}
	sort.Strings(names)
	attrs := make([]slog.Attr, 0, len(names))
	for _, name := range names {
		attrs = append(attrs, slog.String(name, settings[name]))
	}
	return slog.GroupValue(attrs...)
}
