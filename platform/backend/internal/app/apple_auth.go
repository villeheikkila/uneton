package app

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type AppleConfig struct {
	ClientID              string
	TeamID                string
	KeyID                 string
	PrivateKey            string
	ServerNotificationURL string
	TokenURL              string
	KeysURL               string
	RevokeURL             string
	TokenKeyring          string
	TokenActiveKeyID      string
}

func (c AppleConfig) Validate(required bool) error {
	values := []string{c.ClientID, c.TeamID, c.KeyID, c.PrivateKey}
	configured := false
	complete := true
	for _, value := range values {
		configured = configured || strings.TrimSpace(value) != ""
		complete = complete && strings.TrimSpace(value) != ""
	}
	if !configured && !required {
		return nil
	}
	if !complete {
		return errors.New("APPLE_CLIENT_ID, APPLE_TEAM_ID, APPLE_KEY_ID, and APPLE_PRIVATE_KEY must all be configured")
	}
	_, err := parseApplePrivateKey(c.PrivateKey)
	return err
}

func (c AppleConfig) configured() bool { return strings.TrimSpace(c.ClientID) != "" }

type appleIdentity struct {
	Subject      string
	RefreshToken string
}

type AppleAuthenticator struct {
	config        AppleConfig
	client        *http.Client
	mu            sync.Mutex
	keys          map[string]*rsa.PublicKey
	keysFetchedAt time.Time
	tokenURL      string
	keysURL       string
	revokeURL     string
	now           func() time.Time
}

func NewAppleAuthenticator(config AppleConfig) *AppleAuthenticator {
	authenticator := &AppleAuthenticator{
		config: config, client: &http.Client{Timeout: 10 * time.Second},
		tokenURL:  "https://appleid.apple.com/auth/token",
		keysURL:   "https://appleid.apple.com/auth/keys",
		revokeURL: "https://appleid.apple.com/auth/revoke",
		now:       time.Now,
	}
	if strings.TrimSpace(config.TokenURL) != "" {
		authenticator.tokenURL = config.TokenURL
	}
	if strings.TrimSpace(config.KeysURL) != "" {
		authenticator.keysURL = config.KeysURL
	}
	if strings.TrimSpace(config.RevokeURL) != "" {
		authenticator.revokeURL = config.RevokeURL
	}
	return authenticator
}

func (a *AppleAuthenticator) subject(ctx context.Context, authorizationCode, rawNonce string) (appleIdentity, error) {
	clientSecret, err := a.clientSecret()
	if err != nil {
		return appleIdentity{}, err
	}
	form := url.Values{
		"client_id": {a.config.ClientID}, "client_secret": {clientSecret},
		"code": {authorizationCode}, "grant_type": {"authorization_code"},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, a.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return appleIdentity{}, err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := a.client.Do(request)
	if err != nil {
		return appleIdentity{}, err
	}
	defer func() { _ = response.Body.Close() }()
	var tokenResponse struct {
		IDToken      string `json:"id_token"`
		RefreshToken string `json:"refresh_token"`
		Error        string `json:"error"`
	}
	if json.NewDecoder(response.Body).Decode(&tokenResponse) != nil || response.StatusCode != http.StatusOK {
		return appleIdentity{}, fmt.Errorf("apple token exchange failed: %s", tokenResponse.Error)
	}
	exchangedSubject, err := a.validateIdentityToken(tokenResponse.IDToken, rawNonce)
	if err != nil {
		return appleIdentity{}, err
	}
	return appleIdentity{Subject: exchangedSubject, RefreshToken: tokenResponse.RefreshToken}, nil
}

type appleServerNotification struct {
	ID        string
	Type      string
	Subject   string
	EventTime int64
}

func (a *AppleAuthenticator) verifyServerNotification(payload string) (appleServerNotification, error) {
	parsed, err := jwt.Parse(payload, a.keyForToken,
		jwt.WithIssuer("https://appleid.apple.com"),
		jwt.WithAudience(a.config.ClientID),
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithTimeFunc(a.now),
	)
	if err != nil || !parsed.Valid {
		return appleServerNotification{}, errors.New("invalid apple server notification")
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return appleServerNotification{}, errors.New("invalid apple notification claims")
	}
	issuedAt, issuedAtErr := claims.GetIssuedAt()
	if issuedAtErr != nil || issuedAt == nil {
		return appleServerNotification{}, errors.New("apple notification is missing issued-at time")
	}
	id, _ := claims["jti"].(string)
	eventsJSON, _ := claims["events"].(string)
	if strings.TrimSpace(id) == "" || strings.TrimSpace(eventsJSON) == "" {
		return appleServerNotification{}, errors.New("apple notification is missing jti or events")
	}
	var event struct {
		Type      string `json:"type"`
		Subject   string `json:"sub"`
		EventTime int64  `json:"event_time"`
	}
	if err := json.Unmarshal([]byte(eventsJSON), &event); err != nil {
		return appleServerNotification{}, errors.New("invalid apple notification events")
	}
	switch event.Type {
	case "email-enabled", "email-disabled", "consent-revoked", "account-deleted":
	default:
		return appleServerNotification{}, fmt.Errorf("unsupported apple notification event %q", event.Type)
	}
	if strings.TrimSpace(event.Subject) == "" || event.EventTime <= 0 {
		return appleServerNotification{}, errors.New("apple notification event is incomplete")
	}
	return appleServerNotification{ID: id, Type: event.Type, Subject: event.Subject, EventTime: event.EventTime}, nil
}

func (a *AppleAuthenticator) validateIdentityToken(identityToken, rawNonce string) (string, error) {
	parsed, err := jwt.Parse(identityToken, a.keyForToken, jwt.WithIssuer("https://appleid.apple.com"), jwt.WithAudience(a.config.ClientID), jwt.WithValidMethods([]string{"RS256"}), jwt.WithExpirationRequired(), jwt.WithTimeFunc(a.now))
	if err != nil || !parsed.Valid {
		return "", errors.New("invalid apple identity token")
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return "", errors.New("invalid apple claims")
	}
	subject, _ := claims.GetSubject()
	if subject == "" {
		return "", errors.New("missing apple subject")
	}
	nonce, _ := claims["nonce"].(string)
	hash := sha256.Sum256([]byte(rawNonce))
	expectedNonce := hex.EncodeToString(hash[:])
	if len(nonce) != len(expectedNonce) || subtle.ConstantTimeCompare([]byte(nonce), []byte(expectedNonce)) != 1 {
		return "", errors.New("invalid apple nonce")
	}
	return subject, nil
}

func (a *AppleAuthenticator) revoke(ctx context.Context, token string) error {
	clientSecret, err := a.clientSecret()
	if err != nil {
		return err
	}
	form := url.Values{
		"client_id": {a.config.ClientID}, "client_secret": {clientSecret},
		"token": {token}, "token_type_hint": {"refresh_token"},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, a.revokeURL, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := a.client.Do(request)
	if err != nil {
		return err
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("apple token revocation failed with status %d", response.StatusCode)
	}
	return nil
}

// refreshCredential distinguishes Apple's definitive invalid_grant from
// transient provider failures. Only the former authorizes local erasure.
func (a *AppleAuthenticator) refreshCredential(ctx context.Context, refreshToken string) (replacement string, invalidGrant bool, err error) {
	clientSecret, err := a.clientSecret()
	if err != nil {
		return "", false, err
	}
	form := url.Values{
		"client_id": {a.config.ClientID}, "client_secret": {clientSecret},
		"refresh_token": {refreshToken}, "grant_type": {"refresh_token"},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, a.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", false, err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := a.client.Do(request)
	if err != nil {
		return "", false, err
	}
	defer func() { _ = response.Body.Close() }()
	var result struct {
		RefreshToken string `json:"refresh_token"`
		Error        string `json:"error"`
	}
	if decodeErr := json.NewDecoder(response.Body).Decode(&result); decodeErr != nil {
		return "", false, fmt.Errorf("decode apple refresh response: %w", decodeErr)
	}
	if response.StatusCode == http.StatusOK {
		return result.RefreshToken, false, nil
	}
	if result.Error == "invalid_grant" {
		return "", true, nil
	}
	return "", false, fmt.Errorf("apple credential refresh failed with status %d: %s", response.StatusCode, result.Error)
}

func (a *AppleAuthenticator) clientSecret() (string, error) {
	key, err := parseApplePrivateKey(a.config.PrivateKey)
	if err != nil {
		return "", err
	}
	now := a.now().UTC()
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"iss": a.config.TeamID, "iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix(),
		"aud": "https://appleid.apple.com", "sub": a.config.ClientID,
	})
	token.Header["kid"] = a.config.KeyID
	return token.SignedString(key)
}

func parseApplePrivateKey(value string) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(strings.ReplaceAll(value, `\n`, "\n")))
	if block == nil {
		return nil, errors.New("invalid apple private key")
	}
	keyValue, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := keyValue.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apple private key is not EC")
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("apple private key must use the P-256 curve")
	}
	return key, nil
}

func (a *AppleAuthenticator) keyForToken(token *jwt.Token) (any, error) {
	kid, _ := token.Header["kid"].(string)
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.now().Sub(a.keysFetchedAt) > time.Hour || a.keys[kid] == nil {
		request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, a.keysURL, nil)
		if err != nil {
			return nil, err
		}
		response, err := a.client.Do(request)
		if err != nil {
			return nil, err
		}
		defer func() { _ = response.Body.Close() }()
		var set struct {
			Keys []struct {
				Kid string `json:"kid"`
				Kty string `json:"kty"`
				N   string `json:"n"`
				E   string `json:"e"`
			} `json:"keys"`
		}
		if response.StatusCode != http.StatusOK || json.NewDecoder(response.Body).Decode(&set) != nil {
			return nil, errors.New("could not fetch apple keys")
		}
		a.keys = make(map[string]*rsa.PublicKey)
		for _, value := range set.Keys {
			n, err := base64.RawURLEncoding.DecodeString(value.N)
			if err != nil {
				continue
			}
			e, err := base64.RawURLEncoding.DecodeString(value.E)
			if err != nil {
				continue
			}
			exponent := 0
			for _, byteValue := range e {
				exponent = exponent<<8 + int(byteValue)
			}
			a.keys[value.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: exponent}
		}
		a.keysFetchedAt = a.now()
	}
	key := a.keys[kid]
	if key == nil {
		return nil, errors.New("apple signing key not found")
	}
	return key, nil
}
