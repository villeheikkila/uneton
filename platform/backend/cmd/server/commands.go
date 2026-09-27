package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/infra/config"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

func run(ctx context.Context, stdout, stderr io.Writer, args []string) (resultErr error) {
	command := "serve"
	if len(args) > 0 {
		command = args[0]
		args = args[1:]
	}
	if len(args) != 0 {
		return errors.New("unexpected arguments")
	}
	switch command {
	case "serve":
		return serve(ctx, stderr)
	case "config":
		cfg, err := config.FromEnv(config.CurrentEnv())
		if err != nil {
			return fmt.Errorf("load configuration: %w", err)
		}
		return cfg.WriteRedacted(stdout)
	case "database-check":
		cfg, err := config.FromEnv(config.CurrentEnv())
		if err != nil {
			return fmt.Errorf("load configuration: %w", err)
		}
		database, err := store.Open(cfg.DatabasePath)
		if err != nil {
			return fmt.Errorf("open database: %w", err)
		}
		defer func() {
			if closeErr := database.Close(); closeErr != nil && resultErr == nil {
				resultErr = fmt.Errorf("close database: %w", closeErr)
			}
		}()
		var result string
		if err := database.DB.QueryRowContext(ctx, "PRAGMA integrity_check").Scan(&result); err != nil {
			return fmt.Errorf("check database integrity: %w", err)
		}
		if result != "ok" {
			return fmt.Errorf("database integrity check: %s", result)
		}
		_, err = fmt.Fprintln(stdout, "database integrity: ok")
		return err
	case "healthcheck":
		return healthcheck(ctx)
	default:
		return fmt.Errorf("unknown command %q (expected serve, config, database-check, or healthcheck)", command)
	}
}

func healthcheck(ctx context.Context) error {
	address := os.Getenv("UNETON_HTTP_LISTEN_ADDRESS")
	if address == "" {
		address = "127.0.0.1:8080"
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("parse listen address: %w", err)
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+net.JoinHostPort(host, port)+"/health/ready", nil)
	if err != nil {
		return fmt.Errorf("create readiness request: %w", err)
	}
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("check readiness: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("check readiness: HTTP %d", response.StatusCode)
	}
	return nil
}
