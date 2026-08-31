package app

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestAppleAuthenticatorValidatesNonceAndRevokesRefreshToken(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.August, 23, 12, 0, 0, 0, time.UTC)
	clientID := "solutions.bytesized.uneton"
	rawNonce := "one-time-client-nonce"
	nonceHash := sha256.Sum256([]byte(rawNonce))
	appleKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	exchangedToken := signedAppleIdentityToken(t, appleKey, "apple-key", clientID, "apple-subject", hex.EncodeToString(nonceHash[:]), now, "exchange")
	revoked := make(chan url.Values, 1)

	mux := http.NewServeMux()
	mux.HandleFunc("/auth/token", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		if r.Form.Get("code") != "authorization-code" {
			t.Errorf("code = %q", r.Form.Get("code"))
		}
		_ = json.NewEncoder(w).Encode(map[string]string{
			"id_token": exchangedToken, "refresh_token": "apple-refresh-token",
		})
	})
	mux.HandleFunc("/auth/keys", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kid": "apple-key", "kty": "RSA",
			"n": base64.RawURLEncoding.EncodeToString(appleKey.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString([]byte{1, 0, 1}),
		}}})
	})
	mux.HandleFunc("/auth/revoke", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		revoked <- r.Form
		w.WriteHeader(http.StatusOK)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	authenticator := NewAppleAuthenticator(AppleConfig{
		ClientID: clientID, TeamID: "TEAMID", KeyID: "KEYID", PrivateKey: applePrivateKey(t),
	})
	authenticator.now = func() time.Time { return now }
	authenticator.tokenURL = server.URL + "/auth/token"
	authenticator.keysURL = server.URL + "/auth/keys"
	authenticator.revokeURL = server.URL + "/auth/revoke"

	identity, err := authenticator.subject(context.Background(), "authorization-code", rawNonce)
	if err != nil {
		t.Fatal(err)
	}
	if identity.Subject != "apple-subject" || identity.RefreshToken != "apple-refresh-token" {
		t.Fatalf("identity = %#v", identity)
	}
	if _, err := authenticator.subject(context.Background(), "authorization-code", "wrong-nonce"); err == nil {
		t.Fatal("expected a nonce validation error")
	}
	exchangedToken = signedAppleIdentityToken(t, appleKey, "apple-key", "another.client", "apple-subject", hex.EncodeToString(nonceHash[:]), now, "exchange")
	if _, err := authenticator.subject(context.Background(), "authorization-code", rawNonce); err == nil {
		t.Fatal("expected an audience validation error")
	}
	if err := authenticator.revoke(context.Background(), identity.RefreshToken); err != nil {
		t.Fatal(err)
	}
	form := <-revoked
	if form.Get("token") != "apple-refresh-token" || form.Get("token_type_hint") != "refresh_token" {
		t.Fatalf("revoke form = %v", form)
	}
}

func TestAppleConfigurationAndCredentialEncryption(t *testing.T) {
	t.Parallel()
	if err := (AppleConfig{}).Validate(false); err != nil {
		t.Fatal(err)
	}
	if err := (AppleConfig{}).Validate(true); err == nil {
		t.Fatal("expected missing production configuration to fail")
	}
	if err := (AppleConfig{ClientID: "client"}).Validate(true); err == nil {
		t.Fatal("expected incomplete configuration to fail")
	}
	config := AppleConfig{ClientID: "client", TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t)}
	if err := config.Validate(true); err != nil {
		t.Fatal(err)
	}
	ciphertext, err := encryptToken([]byte(strings.Repeat("s", 32)), "refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := decryptToken([]byte(strings.Repeat("s", 32)), ciphertext)
	if err != nil || plaintext != "refresh-token" {
		t.Fatalf("plaintext = %q, error = %v", plaintext, err)
	}
	if _, err := decryptToken([]byte(strings.Repeat("x", 32)), ciphertext); err == nil {
		t.Fatal("expected decryption with a different key to fail")
	}
}

func TestAppleServerNotificationRequiresSignedLifecycleEvent(t *testing.T) {
	now := time.Date(2026, time.August, 30, 12, 0, 0, 0, time.UTC)
	clientID := "solutions.bytesized.uneton"
	appleKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	events, _ := json.Marshal(map[string]any{
		"type": "account-deleted", "sub": "apple-subject", "event_time": now.UnixMilli(),
	})
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": "https://appleid.apple.com", "aud": clientID,
		"iat": now.Add(-time.Minute).Unix(), "exp": now.Add(time.Hour).Unix(),
		"jti": "notification-id", "events": string(events),
	})
	token.Header["kid"] = "apple-key"
	payload, err := token.SignedString(appleKey)
	if err != nil {
		t.Fatal(err)
	}
	keys := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kid": "apple-key", "kty": "RSA",
			"n": base64.RawURLEncoding.EncodeToString(appleKey.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString([]byte{1, 0, 1}),
		}}})
	}))
	defer keys.Close()
	authenticator := NewAppleAuthenticator(AppleConfig{ClientID: clientID, KeysURL: keys.URL})
	authenticator.now = func() time.Time { return now }
	notification, err := authenticator.verifyServerNotification(payload)
	if err != nil {
		t.Fatal(err)
	}
	if notification.ID != "notification-id" || notification.Type != "account-deleted" || notification.Subject != "apple-subject" {
		t.Fatalf("notification = %#v", notification)
	}
}

func TestAppleTokenKeyringRotation(t *testing.T) {
	oldKey := base64.StdEncoding.EncodeToString([]byte("01234567890123456789012345678901"))
	newKey := base64.StdEncoding.EncodeToString([]byte("abcdefghijklmnopqrstuvwxyzABCDEF"))
	oldRing, err := newAppleTokenKeyring(`{"old":"`+oldKey+`"}`, "old", nil)
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, err := oldRing.seal("refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	rotatedRing, err := newAppleTokenKeyring(`{"old":"`+oldKey+`","new":"`+newKey+`"}`, "new", nil)
	if err != nil {
		t.Fatal(err)
	}
	token, needsRewrap, err := rotatedRing.open(ciphertext)
	if err != nil || token != "refresh-token" || !needsRewrap {
		t.Fatalf("token=%q needsRewrap=%v error=%v", token, needsRewrap, err)
	}
}

func signedAppleIdentityToken(t *testing.T, key *rsa.PrivateKey, keyID, audience, subject, nonce string, now time.Time, source string) string {
	t.Helper()
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": "https://appleid.apple.com", "aud": audience, "sub": subject,
		"iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix(), "nonce": nonce,
		"source": source,
	})
	token.Header["kid"] = keyID
	value, err := token.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func applePrivateKey(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded}))
}
