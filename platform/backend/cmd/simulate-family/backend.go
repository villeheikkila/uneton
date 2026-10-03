package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/app"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

// simulatedTokenSecret is stable across restarts and restores, as the
// production secret is, so issued tokens keep verifying.
var simulatedTokenSecret = []byte("simulated-family-token-secret-at-least-32-bytes")

// simClock is the only time source the simulated backend sees. It never moves
// backwards, so token expiry, refresh windows, and journal cutoffs follow it.
type simClock struct {
	mu  sync.Mutex
	now time.Time
}

func newSimClock(start time.Time) *simClock { return &simClock{now: start.UTC()} }

func (c *simClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *simClock) Set(value time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if value.Before(c.now) {
		return fmt.Errorf("simulated time cannot move backwards from %s to %s", c.now.Format(time.RFC3339Nano), value.Format(time.RFC3339Nano))
	}
	c.now = value.UTC()
	return nil
}

type backendOptions struct {
	path                string
	clock               *simClock
	compactionThreshold int
	journalRetention    time.Duration
	// fast trades crash durability of the file for speed; run mode only.
	fast   bool
	logger *slog.Logger
}

type checkpoint struct {
	id   string
	path string
	at   time.Time
}

// backend owns one real Uneton server over a SQLite file and lets the
// simulator restart it or restore an older consistent copy of its database.
type backend struct {
	options     backendOptions
	mu          sync.RWMutex
	store       *store.Store
	server      *app.Server
	checkpoints []checkpoint
	sequence    int
}

func openBackend(options backendOptions) (*backend, error) {
	if options.logger == nil {
		options.logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	b := &backend{options: options}
	if err := b.open(); err != nil {
		return nil, err
	}
	return b, nil
}

func (b *backend) open() error {
	db, err := store.Open(b.options.path)
	if err != nil {
		return fmt.Errorf("open simulated store: %w", err)
	}
	// The simulator is the only process using this file, and simulated crashes
	// are modelled by restarts and restores, not by power loss. An in-memory
	// rollback journal without fsync removes most syscalls; transactions and
	// savepoints keep their semantics.
	pragmas := []string{"PRAGMA synchronous = OFF", "PRAGMA locking_mode = EXCLUSIVE", "PRAGMA cache_size = -131072"}
	if b.options.fast {
		pragmas = append(pragmas, "PRAGMA journal_mode = MEMORY")
	}
	for _, pragma := range pragmas {
		if _, err := db.DB.ExecContext(context.Background(), pragma); err != nil {
			_ = db.Close()
			return fmt.Errorf("configure simulated store: %w", err)
		}
	}
	b.store = db
	b.server = app.NewServer(app.Config{
		Store: db, TokenSecret: simulatedTokenSecret, Development: true, Logger: b.options.logger,
		Now: b.options.clock.Now, SnapshotEventThreshold: b.options.compactionThreshold,
		JournalRetention: b.options.journalRetention,
	})
	return nil
}

func (b *backend) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	b.mu.RLock()
	handler := b.server.Handler()
	defer b.mu.RUnlock()
	handler.ServeHTTP(w, r)
}

// Store exposes the current authoritative database to invariant checks.
func (b *backend) Store() *store.Store {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.store
}

func (b *backend) Generation() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.store.SyncGeneration
}

// swap stops the current server, runs change against the closed database
// files, and reopens. Streams are told to finish first so the write lock is
// not held up by long-lived WatchFamily requests.
func (b *backend) swap(change func() error) error {
	b.mu.RLock()
	current := b.server
	b.mu.RUnlock()
	current.MarkNotReady()
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.store.Close(); err != nil {
		return fmt.Errorf("close simulated store: %w", err)
	}
	if change != nil {
		if err := change(); err != nil {
			return err
		}
	}
	return b.open()
}

func (b *backend) Restart() error { return b.swap(nil) }

// Checkpoint writes a transactionally consistent copy with VACUUM INTO, never
// a raw copy of a live WAL database.
func (b *backend) Checkpoint() (checkpoint, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.sequence++
	id := fmt.Sprintf("checkpoint-%06d", b.sequence)
	path := b.options.path + "." + id
	quoted := "'" + strings.ReplaceAll(path, "'", "''") + "'"
	if _, err := b.store.DB.ExecContext(context.Background(), "VACUUM INTO "+quoted); err != nil {
		return checkpoint{}, fmt.Errorf("checkpoint simulated store: %w", err)
	}
	value := checkpoint{id: id, path: path, at: b.options.clock.Now()}
	b.checkpoints = append(b.checkpoints, value)
	return value, nil
}

// PruneCheckpoints removes checkpoints older than the restore horizon, the way
// Litestream retention drops old snapshots.
func (b *backend) PruneCheckpoints(horizon time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.options.clock.Now()
	kept := b.checkpoints[:0]
	for _, value := range b.checkpoints {
		if now.Sub(value.at) > horizon {
			_ = os.Remove(value.path)
			continue
		}
		kept = append(kept, value)
	}
	b.checkpoints = kept
}

func (b *backend) Checkpoints() []checkpoint {
	b.mu.RLock()
	defer b.mu.RUnlock()
	values := append([]checkpoint(nil), b.checkpoints...)
	sort.Slice(values, func(i, j int) bool { return values[i].at.Before(values[j].at) })
	return values
}

// Restore replaces the database with a checkpoint and rotates the generation
// sidecar, as the production restore procedure must before the API starts.
func (b *backend) Restore(id string) (checkpoint, error) {
	var selected *checkpoint
	for _, value := range b.Checkpoints() {
		if value.id == id {
			value := value
			selected = &value
		}
	}
	if selected == nil {
		return checkpoint{}, fmt.Errorf("unknown checkpoint %q", id)
	}
	err := b.swap(func() error {
		path := b.options.path
		for _, suffix := range []string{"", "-wal", "-shm"} {
			if err := os.Remove(path + suffix); err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("remove database before restore: %w", err)
			}
		}
		if err := copyFile(selected.path, path); err != nil {
			return fmt.Errorf("restore checkpoint: %w", err)
		}
		var bytes [16]byte
		if _, err := rand.Read(bytes[:]); err != nil {
			return err
		}
		return os.WriteFile(path+".sync-generation", []byte(hex.EncodeToString(bytes[:])+"\n"), 0o600)
	})
	return *selected, err
}

func (b *backend) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.server.MarkNotReady()
	_ = b.store.Close()
	for _, value := range b.checkpoints {
		_ = os.Remove(value.path)
	}
}

func copyFile(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer func() { _ = input.Close() }()
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return err
	}
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		_ = output.Close()
		return err
	}
	return output.Close()
}
