package app

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
)

const appleTokenCiphertextVersion = "u1"

type appleTokenKeyring struct {
	active string
	keys   map[string][]byte
}

func newAppleTokenKeyring(raw, active string, developmentFallback []byte) (*appleTokenKeyring, error) {
	if raw == "" {
		if len(developmentFallback) == 0 {
			return nil, errors.New("apple token encryption keyring is empty")
		}
		return &appleTokenKeyring{active: "development", keys: map[string][]byte{"development": developmentFallback}}, nil
	}
	var encoded map[string]string
	if err := json.Unmarshal([]byte(raw), &encoded); err != nil {
		return nil, fmt.Errorf("decode apple token keyring: %w", err)
	}
	keyring := &appleTokenKeyring{active: active, keys: make(map[string][]byte, len(encoded))}
	for id, value := range encoded {
		key, err := base64.StdEncoding.DecodeString(value)
		if err != nil || len(key) != 32 {
			return nil, fmt.Errorf("decode Apple token key %q", id)
		}
		keyring.keys[id] = key
	}
	if keyring.keys[active] == nil {
		return nil, errors.New("active apple token key is missing")
	}
	return keyring, nil
}

func (k *appleTokenKeyring) seal(token string) ([]byte, error) {
	ciphertext, err := encryptToken(k.keys[k.active], token)
	if err != nil {
		return nil, err
	}
	prefix := []byte(appleTokenCiphertextVersion + ":" + k.active + ":")
	return append(prefix, ciphertext...), nil
}

func (k *appleTokenKeyring) open(ciphertext []byte) (token string, needsRewrap bool, err error) {
	parts := bytes.SplitN(ciphertext, []byte(":"), 3)
	if len(parts) != 3 || string(parts[0]) != appleTokenCiphertextVersion {
		return "", false, errors.New("invalid apple token ciphertext envelope")
	}
	keyID := string(parts[1])
	key := k.keys[keyID]
	if key == nil {
		return "", false, fmt.Errorf("apple token key %q is unavailable", keyID)
	}
	token, err = decryptToken(key, parts[2])
	return token, keyID != k.active, err
}
