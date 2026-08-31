package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/infra/config"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

type Runner struct{ logger *slog.Logger }

func NewRunner(logger *slog.Logger) *Runner {
	if logger == nil {
		logger = slog.Default()
	}
	return &Runner{logger: logger}
}

func (r *Runner) Run(ctx context.Context, cfg config.Config) error {
	if err := os.MkdirAll(filepath.Dir(cfg.DatabasePath), 0o750); err != nil {
		return fmt.Errorf("create database directory: %w", err)
	}
	database, err := store.Open(cfg.DatabasePath)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	defer func() {
		if closeErr := database.Close(); closeErr != nil {
			r.logger.ErrorContext(ctx, "close database", "error", closeErr)
		}
	}()
	appleConfig := AppleConfig{
		ClientID:              cfg.Apple.ClientID,
		TeamID:                cfg.Apple.TeamID,
		KeyID:                 cfg.Apple.KeyID,
		PrivateKey:            cfg.Apple.PrivateKey.Reveal(),
		ServerNotificationURL: cfg.Apple.ServerNotificationURL,
		TokenURL:              cfg.Apple.TokenURL,
		KeysURL:               cfg.Apple.KeysURL,
		RevokeURL:             cfg.Apple.RevokeURL,
		TokenKeyring:          cfg.Apple.TokenKeyring.Reveal(),
		TokenActiveKeyID:      cfg.Apple.TokenActiveKeyID,
	}
	if err := appleConfig.Validate(cfg.Environment == config.Production); err != nil {
		return fmt.Errorf("validate Apple integration: %w", err)
	}
	handler := NewServer(Config{
		Store:       database,
		TokenSecret: []byte(cfg.TokenSecret.Reveal()),
		Development: cfg.Environment == config.Development,
		Logger:      r.logger,
		Apple:       appleConfig,
		APNS: APNSConfig{
			TeamID: cfg.APNS.TeamID, KeyID: cfg.APNS.KeyID,
			PrivateKey: cfg.APNS.PrivateKey.Reveal(), Topic: cfg.APNS.Topic,
		},
	})
	if err := handler.RewrapAppleTokens(ctx); err != nil {
		return fmt.Errorf("rewrap Apple credentials: %w", err)
	}
	go handler.RunAppleCredentialAudit(ctx, 24*time.Hour)
	go handler.RunPushDeliveries(ctx)
	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", cfg.HTTPAddress)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.HTTPAddress, err)
	}
	httpServer := &http.Server{
		Addr:              cfg.HTTPAddress,
		Handler:           handler.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       90 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return context.WithoutCancel(ctx) },
	}
	errCh := make(chan error, 1)
	go func() {
		r.logger.InfoContext(ctx, "server listening", "address", listener.Addr().String(), "environment", cfg.Environment)
		err := httpServer.Serve(listener)
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errCh <- err
	}()
	select {
	case <-ctx.Done():
		handler.MarkNotReady()
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cfg.ShutdownTimeout)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	case err := <-errCh:
		if err == nil {
			return errors.New("HTTP server stopped unexpectedly")
		}
		return fmt.Errorf("HTTP server: %w", err)
	}
}
