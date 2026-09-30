package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type APNSProvider struct {
	teamID, keyID, topic string
	privateKey           string
	client               *http.Client
	now                  func() time.Time
	endpoint             func(string) string
}

type APNSConfig struct {
	TeamID     string
	KeyID      string
	PrivateKey string
	Topic      string
}

func (c APNSConfig) Validate() error {
	configured, complete := false, true
	for _, value := range []string{c.TeamID, c.KeyID, c.PrivateKey, c.Topic} {
		configured = configured || strings.TrimSpace(value) != ""
		complete = complete && strings.TrimSpace(value) != ""
	}
	if !configured {
		return nil
	}
	if !complete {
		return errors.New("APNs team ID, key ID, private key and topic must all be configured")
	}
	_, err := parseApplePrivateKey(c.PrivateKey)
	return err
}

func NewAPNSProvider(config APNSConfig) *APNSProvider {
	if strings.TrimSpace(config.Topic) == "" {
		return nil
	}
	return &APNSProvider{
		teamID: config.TeamID, keyID: config.KeyID, topic: config.Topic,
		privateKey: config.PrivateKey, client: &http.Client{Timeout: 10 * time.Second}, now: time.Now,
		endpoint: func(environment string) string {
			if environment == "development" {
				return "https://api.sandbox.push.apple.com"
			}
			return "https://api.push.apple.com"
		},
	}
}

func (p *APNSProvider) send(ctx context.Context, token, environment, pushType, topic, priority, collapseID string, payload any) (invalidToken bool, err error) {
	return p.sendWithExpiration(ctx, token, environment, pushType, topic, priority, collapseID, p.now().Add(24*time.Hour), payload)
}

func (p *APNSProvider) sendWithExpiration(ctx context.Context, token, environment, pushType, topic, priority, collapseID string, expiration time.Time, payload any) (invalidToken bool, err error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return false, err
	}
	key, err := parseApplePrivateKey(p.privateKey)
	if err != nil {
		return false, err
	}
	claim := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": p.teamID, "iat": p.now().Unix()})
	claim.Header["kid"] = p.keyID
	authorization, err := claim.SignedString(key)
	if err != nil {
		return false, err
	}
	host := p.endpoint(environment)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	request.Header.Set("authorization", "bearer "+authorization)
	request.Header.Set("apns-push-type", pushType)
	request.Header.Set("apns-topic", topic)
	request.Header.Set("apns-priority", priority)
	request.Header.Set("apns-expiration", strconv.FormatInt(expiration.Unix(), 10))
	if collapseID != "" {
		request.Header.Set("apns-collapse-id", collapseID)
	}
	response, err := p.client.Do(request)
	if err != nil {
		// net/http errors can include the request URL, which contains a push token.
		return false, &apnsTransportError{cause: err}
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode == http.StatusOK {
		return false, nil
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(response.Body).Decode(&failure)
	invalid := response.StatusCode == http.StatusGone || failure.Reason == "BadDeviceToken" || failure.Reason == "Unregistered"
	return invalid, fmt.Errorf("APNs status %d: %s", response.StatusCode, failure.Reason)
}

func (p *APNSProvider) alert(ctx context.Context, token, environment, title, body, collapseID string) (bool, error) {
	return p.send(ctx, token, environment, "alert", p.topic, "10", collapseID, map[string]any{"aps": map[string]any{"alert": map[string]string{"title": title, "body": body}, "sound": "default"}})
}

func (p *APNSProvider) background(ctx context.Context, token, environment, familyID string) (bool, error) {
	return p.send(ctx, token, environment, "background", p.topic, "5", "family-"+familyID, map[string]any{
		"aps": map[string]any{"content-available": 1}, "familyID": familyID,
	})
}

func (p *APNSProvider) liveActivity(ctx context.Context, token, environment, event string, attributes map[string]any, contentState map[string]any, collapseID string) (bool, error) {
	aps := map[string]any{"timestamp": p.now().Unix(), "event": event, "content-state": contentState}
	if event == "start" {
		aps["attributes-type"] = "SleepActivityAttributes"
		aps["attributes"] = attributes
		aps["input-push-token"] = 1
	}
	return p.send(ctx, token, environment, "liveactivity", p.topic+".push-type.liveactivity", "10", collapseID, map[string]any{"aps": aps})
}

func appleReferenceSeconds(value time.Time) float64 {
	return value.Sub(time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)).Seconds()
}

// Keep the cause for errors.Is/As without exposing token-bearing URLs in logs.
type apnsTransportError struct{ cause error }

func (e *apnsTransportError) Error() string { return "APNs transport request failed" }
func (e *apnsTransportError) Unwrap() error { return e.cause }
