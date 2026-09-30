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
	"sync"
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

// Run owns every resource from startup through final cleanup.
func (r *Runner) Run(ctx context.Context, cfg config.Config) error {
	rt, err := r.buildRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	runErr := rt.wait(ctx)
	return errors.Join(runErr, rt.shutdown(ctx))
}

// buildRuntime validates integrations before opening SQLite or binding HTTP.
// Failed startup releases acquired resources without starting workers.
func (r *Runner) buildRuntime(ctx context.Context, cfg config.Config) (_ *runtime, err error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("validate configuration: %w", err)
	}
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
		return nil, fmt.Errorf("validate Apple integration: %w", err)
	}
	apnsConfig := APNSConfig{
		TeamID: cfg.APNS.TeamID, KeyID: cfg.APNS.KeyID,
		PrivateKey: cfg.APNS.PrivateKey.Reveal(), Topic: cfg.APNS.Topic,
	}
	if err := apnsConfig.Validate(); err != nil {
		return nil, fmt.Errorf("validate APNs integration: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(cfg.DatabasePath), 0o750); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	database, err := store.Open(cfg.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	defer func() {
		if err != nil {
			err = errors.Join(err, database.Close())
		}
	}()
	handler := NewServer(Config{
		Store:             database,
		TokenSecret:       []byte(cfg.TokenSecret.Reveal()),
		Development:       cfg.Environment == config.Development,
		Logger:            r.logger,
		LegalOperator:     cfg.LegalOperator,
		LegalContactEmail: cfg.LegalEmail,
		Apple:             appleConfig,
		APNS:              apnsConfig,
	})
	if err := handler.RewrapAppleTokens(ctx); err != nil {
		return nil, fmt.Errorf("rewrap Apple credentials: %w", err)
	}
	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", cfg.HTTPAddress)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", cfg.HTTPAddress, err)
	}

	rt := r.startRuntime(ctx, cfg, listener, handler)
	rt.database = database
	return rt, nil
}

type runtime struct {
	cfg          config.Config
	handler      *Server
	database     *store.Store
	listener     net.Listener
	httpServer   *http.Server
	requests     *requestDrain
	stopRequests context.CancelFunc
	stopWorkers  context.CancelFunc
	workers      sync.WaitGroup
	serverErr    chan error
	serverDone   chan struct{}
}

// serve is also used by lifecycle tests with an externally owned database.
func (r *Runner) serve(ctx context.Context, cfg config.Config, listener net.Listener, handler *Server) error {
	rt := r.startRuntime(ctx, cfg, listener, handler)
	return errors.Join(rt.wait(ctx), rt.shutdown(ctx))
}

func (r *Runner) startRuntime(ctx context.Context, cfg config.Config, listener net.Listener, handler *Server) *runtime {
	workersCtx, stopWorkers := context.WithCancel(context.WithoutCancel(ctx))
	requestsCtx, stopRequests := context.WithCancel(context.WithoutCancel(ctx))
	rt := &runtime{
		cfg: cfg, handler: handler, listener: listener,
		requests:     &requestDrain{handler: handler.Handler()},
		stopRequests: stopRequests, stopWorkers: stopWorkers,
		serverErr: make(chan error, 1), serverDone: make(chan struct{}),
	}
	rt.httpServer = &http.Server{
		Addr: cfg.HTTPAddress, Handler: rt.requests,
		ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 90 * time.Second,
		BaseContext: func(net.Listener) context.Context { return requestsCtx },
	}
	rt.workers.Go(func() { handler.RunAppleCredentialAudit(workersCtx, 24*time.Hour) })
	rt.workers.Go(func() { handler.RunPushDeliveries(workersCtx) })
	go func() {
		defer close(rt.serverDone)
		r.logger.InfoContext(ctx, "server listening", "address", listener.Addr().String(), "environment", cfg.Environment)
		rt.serverErr <- rt.httpServer.Serve(listener)
	}()
	return rt
}

func (rt *runtime) wait(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return nil
	case err := <-rt.serverErr:
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			return errors.New("HTTP server stopped unexpectedly")
		}
		return fmt.Errorf("HTTP server: %w", err)
	}
}

func (rt *runtime) shutdown(ctx context.Context) error {
	rt.handler.MarkNotReady()
	rt.stopWorkers()
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), rt.cfg.ShutdownTimeout)
	defer cancel()
	shutdownErr := rt.httpServer.Shutdown(shutdownCtx)
	// Stop admission before waiting, including on forced shutdown.
	rt.requests.stop()
	rt.stopRequests()
	closeErr := rt.httpServer.Close()
	_ = rt.listener.Close()
	rt.requests.active.Wait()
	rt.workers.Wait()
	<-rt.serverDone
	var databaseErr error
	if rt.database != nil {
		databaseErr = rt.database.Close()
	}
	return errors.Join(shutdownErr, closeErr, databaseErr)
}

// Closing admission makes Add/Wait safe even after forced HTTP shutdown.
type requestDrain struct {
	handler http.Handler
	mu      sync.Mutex
	stopped bool
	active  sync.WaitGroup
}

func (d *requestDrain) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	if d.stopped {
		d.mu.Unlock()
		http.Error(w, "server is draining", http.StatusServiceUnavailable)
		return
	}
	d.active.Add(1)
	d.mu.Unlock()
	defer d.active.Done()
	d.handler.ServeHTTP(w, r)
}

func (d *requestDrain) stop() {
	d.mu.Lock()
	d.stopped = true
	d.mu.Unlock()
}
