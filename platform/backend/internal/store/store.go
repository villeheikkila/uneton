package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"

	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

type Store struct {
	DB             *sql.DB
	Queries        *storedb.Queries
	SyncGeneration string
}

func Open(path string) (*Store, error) {
	dsn := path
	if path != ":memory:" {
		dsn = "file:" + path
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// SQLite supports concurrent readers but only one writer. A single pooled
	// connection also guarantees that connection-scoped pragmas apply to every
	// query and prevents concurrent sync transactions from failing with BUSY.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	for _, pragma := range []string{
		"PRAGMA foreign_keys = ON",
		"PRAGMA journal_mode = WAL",
		"PRAGMA synchronous = NORMAL",
		"PRAGMA busy_timeout = 5000",
	} {
		if _, err := db.ExecContext(context.Background(), pragma); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("configure sqlite: %w", err)
		}
	}
	generation, err := syncGeneration(path)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	s := &Store{DB: db, Queries: storedb.New(db), SyncGeneration: generation}
	if err := s.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func syncGeneration(path string) (string, error) {
	if path == ":memory:" {
		return newSyncGeneration()
	}
	generationPath := path + ".sync-generation"
	if value, err := os.ReadFile(generationPath); err == nil {
		generation := strings.TrimSpace(string(value))
		if generation == "" {
			return "", fmt.Errorf("sync generation file %s is empty", generationPath)
		}
		return generation, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("read sync generation: %w", err)
	}
	generation, err := newSyncGeneration()
	if err != nil {
		return "", err
	}
	file, err := os.OpenFile(generationPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		value, readErr := os.ReadFile(generationPath)
		if readErr != nil {
			return "", fmt.Errorf("read concurrently created sync generation: %w", readErr)
		}
		return strings.TrimSpace(string(value)), nil
	}
	if err != nil {
		return "", fmt.Errorf("create sync generation: %w", err)
	}
	if _, err := file.WriteString(generation + "\n"); err != nil {
		_ = file.Close()
		return "", fmt.Errorf("write sync generation: %w", err)
	}
	if err := file.Close(); err != nil {
		return "", fmt.Errorf("close sync generation: %w", err)
	}
	return generation, nil
}

func newSyncGeneration() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", fmt.Errorf("generate sync generation: %w", err)
	}
	return hex.EncodeToString(bytes[:]), nil
}

func (s *Store) Close() error { return s.DB.Close() }

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.DB.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY NOT NULL, applied_at TEXT NOT NULL) STRICT`); err != nil {
		return err
	}
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		var applied int
		err := s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, entry.Name()).Scan(&applied)
		if err != nil {
			return err
		}
		if applied != 0 {
			continue
		}
		body, err := migrationFiles.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return err
		}
		tx, err := s.DB.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, string(body)); err == nil {
			_, err = tx.ExecContext(ctx, `INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)`, entry.Name(), time.Now().UTC().Format(time.RFC3339Nano))
		}
		if err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("migration %s: %w", entry.Name(), err)
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}
