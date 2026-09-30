package config

import (
	"log/slog"
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
	LegalOperator   string
	LegalEmail      string
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
