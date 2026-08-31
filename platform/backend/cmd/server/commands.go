package main

import (
	"context"
	"errors"
	"fmt"
	"io"

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
	default:
		return fmt.Errorf("unknown command %q (expected serve, config, or database-check)", command)
	}
}
