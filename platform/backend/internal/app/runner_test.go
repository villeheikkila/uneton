package app

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/common/secret"
	"solutions.bytesized/uneton/platform/backend/internal/infra/config"
	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func bootstrapConfig(t *testing.T) config.Config {
	t.Helper()
	return config.Config{
		Environment: config.Development, HTTPAddress: "127.0.0.1:0",
		DatabasePath: filepath.Join(t.TempDir(), "bootstrap.sqlite"),
		LogFormat:    "pretty", LegalOperator: "Uneton", LegalEmail: "support@example.invalid",
		TokenSecret: secret.New("test-secret-that-is-at-least-thirty-two-bytes"), ShutdownTimeout: time.Second,
	}
}

func bootstrapRunner() *Runner { return NewRunner(slog.New(slog.DiscardHandler)) }

func awaitRunner(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("runner did not finish cleanup")
		return nil
	}
}

func startBootstrapFixture(t *testing.T, f *reminderFixture, grace time.Duration) (string, context.CancelFunc, <-chan error, net.Listener) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		done <- bootstrapRunner().serve(ctx, config.Config{ShutdownTimeout: grace}, listener, f.s)
	}()
	t.Cleanup(func() {
		cancel()
		_ = listener.Close()
		select {
		case <-finished:
		case <-time.After(3 * time.Second):
			t.Error("runner cleanup timed out")
		}
	})
	return "http://" + listener.Addr().String(), cancel, done, listener
}

func TestRunnerDrainsAnActiveFamilyStream(t *testing.T) {
	f := newReminderFixture(t)
	f.s.apns = nil
	f.s.streamHeartbeat = 10 * time.Millisecond
	url, cancel, done, _ := startBootstrapFixture(t, f, time.Second)
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, url)
	cursor, err := f.s.store.Queries.LatestFamilyCursor(context.Background(), f.familyID)
	if err != nil {
		t.Fatal(err)
	}
	watchCtx, stopWatch := context.WithTimeout(context.Background(), 3*time.Second)
	defer stopWatch()
	request := connect.NewRequest(&unetonv1.WatchFamilyRequest{FamilyId: f.familyID, AfterCursor: cursor, Generation: f.s.store.SyncGeneration})
	authorize(request, f.auth.GetAccessToken())
	stream, err := client.WatchFamily(watchCtx, request)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = stream.Close() }()
	if !stream.Receive() {
		t.Fatalf("stream not established: %v", stream.Err())
	}
	cancel()
	if err := awaitRunner(t, done); err != nil {
		t.Fatalf("active stream prevented graceful shutdown: %v", err)
	}
	if stream.Receive() {
		t.Fatal("stream remained active after runner returned")
	}
	// Repeated drain requests must be safe.
	f.s.MarkNotReady()
}

func TestRunnerClosesOverdueRequestsBeforeReturning(t *testing.T) {
	f := newReminderFixture(t)
	f.s.apns = nil
	started, exited := make(chan struct{}), make(chan struct{})
	f.s.mux.HandleFunc("GET /blocking", func(_ http.ResponseWriter, request *http.Request) {
		close(started)
		<-request.Context().Done()
		close(exited)
	})
	url, cancel, done, _ := startBootstrapFixture(t, f, 20*time.Millisecond)
	requestDone := make(chan struct{})
	go func() {
		defer close(requestDone)
		response, err := http.Get(url + "/blocking")
		if err == nil {
			_ = response.Body.Close()
		}
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	cancel()
	if err := awaitRunner(t, done); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("overdue request shutdown = %v", err)
	}
	select {
	case <-exited:
	default:
		t.Fatal("runner returned before request handler stopped")
	}
	select {
	case <-requestDone:
	case <-time.After(time.Second):
		t.Fatal("HTTP connection remained open")
	}
}

func TestRunnerStopsWorkersAfterUnexpectedServeFailure(t *testing.T) {
	f := newReminderFixture(t)
	if err := registerActivity(f, registrationSession, registrationToken, 1); err != nil {
		t.Fatal(err)
	}
	entered, exited := make(chan struct{}), make(chan struct{})
	var began, stopped sync.Once
	f.s.apns.client = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		began.Do(func() { close(entered) })
		<-request.Context().Done()
		stopped.Do(func() { close(exited) })
		return nil, request.Context().Err()
	})}
	_, _, done, listener := startBootstrapFixture(t, f, time.Second)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("push worker did not start")
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if err := awaitRunner(t, done); err == nil || !strings.Contains(err.Error(), "HTTP server") {
		t.Fatalf("serve failure = %v", err)
	}
	select {
	case <-exited:
	default:
		t.Fatal("push worker survived runner return")
	}
}

func TestRunnerBindFailureDoesNotStartPushRecovery(t *testing.T) {
	f := newReminderFixture(t)
	rows, err := f.s.store.Queries.DueDeliveries(context.Background(), storedb.DueDeliveriesParams{Now: formatTime(f.now), ResultLimit: 1})
	if err != nil || len(rows) != 1 {
		t.Fatalf("test deliveries = %+v, %v", rows, err)
	}
	if _, err := f.s.store.Queries.MarkDeliverySending(context.Background(), rows[0].ID); err != nil {
		t.Fatal(err)
	}
	if err := f.s.store.Close(); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()
	cfg := bootstrapConfig(t)
	cfg.DatabasePath = f.path
	cfg.HTTPAddress = listener.Addr().String()
	cfg.APNS = config.APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: secret.New(applePrivateKey(t)), Topic: "solutions.bytesized.uneton"}
	if err := bootstrapRunner().Run(context.Background(), cfg); err == nil || !strings.Contains(err.Error(), "listen on") {
		t.Fatalf("bind failure = %v", err)
	}
	reopened, err := store.Open(f.path)
	if err != nil {
		t.Fatal(err)
	}
	f.s.store = reopened
	var status string
	if err := reopened.DB.QueryRowContext(context.Background(), "select status from deliveries where id=?", rows[0].ID).Scan(&status); err != nil || status != "sending" {
		t.Fatalf("worker recovery ran before bind: %q, %v", status, err)
	}
}

func TestRunnerRejectsMalformedAPNSKey(t *testing.T) {
	cfg := bootstrapConfig(t)
	cfg.APNS = config.APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: secret.New("malformed-private-key"), Topic: "solutions.bytesized.uneton"}
	if err := bootstrapRunner().Run(context.Background(), cfg); err == nil || !strings.Contains(err.Error(), "validate APNs integration") {
		t.Fatalf("invalid APNs startup = %v", err)
	}
	if _, err := os.Stat(cfg.DatabasePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("invalid credentials opened SQLite: %v", err)
	}
}
