package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"solutions.bytesized/uneton/platform/backend/internal/app"
	"solutions.bytesized/uneton/platform/backend/internal/infra/config"
)

func serve(ctx context.Context, stderr io.Writer) error {
	cfg, err := config.FromEnv(config.CurrentEnv())
	if err != nil {
		return fmt.Errorf("load configuration: %w", err)
	}
	options := &slog.HandlerOptions{Level: cfg.LogLevel, AddSource: cfg.LogLevel == slog.LevelDebug}
	var handler slog.Handler
	if cfg.LogFormat == "json" {
		handler = slog.NewJSONHandler(stderr, options)
	} else {
		handler = slog.NewTextHandler(stderr, options)
	}
	logger := slog.New(handler)
	previous := slog.Default()
	slog.SetDefault(logger)
	defer slog.SetDefault(previous)
	runCtx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	return app.NewRunner(logger).Run(runCtx, cfg)
}
