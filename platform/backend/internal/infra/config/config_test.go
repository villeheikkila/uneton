package config

import (
	"bytes"
	"strings"
	"testing"
)

func TestFromEnvRejectsUnknownProjectVariable(t *testing.T) {
	values := developmentEnvironment()
	values["UNETON_DATABASE_PTAH"] = "typo"
	if _, err := FromEnv(values); err == nil || !strings.Contains(err.Error(), "UNETON_DATABASE_PTAH") {
		t.Fatalf("error = %v", err)
	}
}

func TestProductionRequiresNotificationAndTokenKeyring(t *testing.T) {
	values := developmentEnvironment()
	values["UNETON_RUNTIME_ENVIRONMENT"] = "production"
	values["UNETON_AUTH_APPLE_CLIENT_ID"] = "solutions.bytesized.uneton"
	values["UNETON_INTEGRATION_APPLE_TEAM_ID"] = "team"
	values["UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID"] = "key"
	values["UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM"] = "private"
	if _, err := FromEnv(values); err == nil || !strings.Contains(err.Error(), "SERVER_NOTIFICATION_URL") {
		t.Fatalf("error = %v", err)
	}
	values["UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL"] = "https://api.uneton.app/apple/server-notifications"
	if _, err := FromEnv(values); err == nil || !strings.Contains(err.Error(), "keyring") {
		t.Fatalf("error = %v", err)
	}
	values["UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID"] = "current"
	values["UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON"] = `{"current":"MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="}`
	if _, err := FromEnv(values); err != nil {
		t.Fatal(err)
	}
}

func TestWriteRedactedNeverPrintsSecrets(t *testing.T) {
	values := developmentEnvironment()
	values["UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID"] = "current"
	values["UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON"] = `{"current":"MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="}`
	cfg, err := FromEnv(values)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := cfg.WriteRedacted(&output); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), values["UNETON_AUTH_TOKEN_SECRET"]) || strings.Contains(output.String(), "MDEyMzQ1") {
		t.Fatalf("redacted output leaked a secret: %s", output.String())
	}
}

func TestAPNSConfigurationCanUseDedicatedOrAppleKey(t *testing.T) {
	values := developmentEnvironment()
	values["UNETON_AUTH_APPLE_CLIENT_ID"] = "solutions.bytesized.uneton"
	values["UNETON_INTEGRATION_APPLE_TEAM_ID"] = "apple-team"
	values["UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID"] = "apple-key"
	values["UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM"] = "apple-private"
	cfg, err := FromEnv(values)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.APNS.Topic != values["UNETON_AUTH_APPLE_CLIENT_ID"] || cfg.APNS.KeyID != "apple-key" {
		t.Fatalf("APNS fallback = %#v", cfg.APNS)
	}
	values["UNETON_INTEGRATION_APNS_TOPIC"] = "solutions.bytesized.uneton"
	if _, err := FromEnv(values); err == nil || !strings.Contains(err.Error(), "APNs") {
		t.Fatalf("partial APNs error = %v", err)
	}
}

func developmentEnvironment() map[string]string {
	return map[string]string{
		"UNETON_RUNTIME_ENVIRONMENT": "development",
		"UNETON_AUTH_TOKEN_SECRET":   "development-secret-at-least-32-characters",
	}
}
