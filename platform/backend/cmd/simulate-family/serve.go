package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// serveCommand runs the real API on a simulated clock for external harnesses
// such as the Swift SyncCoordinator simulation. The /_sim/ control endpoints
// exist only in this binary, never in cmd/server.
func serveCommand(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ExitOnError)
	address := flags.String("addr", "127.0.0.1:0", "listen address")
	path := flags.String("db", "", "SQLite database path (required)")
	start := flags.String("start", "", "initial simulated time, RFC 3339 (required)")
	threshold := flags.Int("compaction-threshold", 2000, "server event count that triggers compaction")
	retention := flags.Duration("journal-retention", 7*24*time.Hour, "server journal retention")
	_ = flags.Parse(args)
	if *path == "" || *start == "" {
		return fmt.Errorf("serve requires -db and -start")
	}
	initial, err := time.Parse(time.RFC3339Nano, *start)
	if err != nil {
		return fmt.Errorf("invalid -start: %w", err)
	}
	clock := newSimClock(initial)
	b, err := openBackend(backendOptions{path: *path, clock: clock, compactionThreshold: *threshold, journalRetention: *retention})
	if err != nil {
		return err
	}
	defer b.Close()
	listener, err := net.Listen("tcp", *address)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: controlMux(b, clock), ReadHeaderTimeout: 10 * time.Second}
	fmt.Printf("READY http://%s\n", listener.Addr().String())
	_ = os.Stdout.Sync()
	errs := make(chan error, 1)
	go func() { errs <- server.Serve(listener) }()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errs:
		return err
	case <-signals:
		return server.Close()
	}
}

func controlMux(b *backend, clock *simClock) *http.ServeMux {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, status int, value any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(value)
	}
	failure := func(w http.ResponseWriter, status int, err error) {
		reply(w, status, map[string]string{"error": err.Error()})
	}
	clockReply := func(w http.ResponseWriter) {
		reply(w, http.StatusOK, map[string]string{"now": clock.Now().Format(time.RFC3339Nano)})
	}
	mux.HandleFunc("GET /_sim/clock", func(w http.ResponseWriter, _ *http.Request) { clockReply(w) })
	mux.HandleFunc("POST /_sim/clock", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Now            *string  `json:"now"`
			AdvanceSeconds *float64 `json:"advanceSeconds"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || (body.Now == nil) == (body.AdvanceSeconds == nil) {
			failure(w, http.StatusBadRequest, fmt.Errorf("send exactly one of now or advanceSeconds"))
			return
		}
		var target time.Time
		if body.Now != nil {
			parsed, err := time.Parse(time.RFC3339Nano, *body.Now)
			if err != nil {
				failure(w, http.StatusBadRequest, err)
				return
			}
			target = parsed
		} else {
			if *body.AdvanceSeconds < 0 || math.IsNaN(*body.AdvanceSeconds) || math.IsInf(*body.AdvanceSeconds, 0) {
				failure(w, http.StatusBadRequest, fmt.Errorf("advanceSeconds must be a non-negative number"))
				return
			}
			target = clock.Now().Add(time.Duration(*body.AdvanceSeconds * float64(time.Second)))
		}
		if err := clock.Set(target); err != nil {
			failure(w, http.StatusBadRequest, err)
			return
		}
		clockReply(w)
	})
	mux.HandleFunc("POST /_sim/restart", func(w http.ResponseWriter, _ *http.Request) {
		if err := b.Restart(); err != nil {
			failure(w, http.StatusInternalServerError, err)
			return
		}
		reply(w, http.StatusOK, map[string]string{"generation": b.Generation()})
	})
	mux.HandleFunc("POST /_sim/checkpoint", func(w http.ResponseWriter, _ *http.Request) {
		value, err := b.Checkpoint()
		if err != nil {
			failure(w, http.StatusInternalServerError, err)
			return
		}
		reply(w, http.StatusOK, map[string]string{"id": value.id})
	})
	mux.HandleFunc("POST /_sim/restore", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.ID == "" {
			failure(w, http.StatusBadRequest, fmt.Errorf("send the checkpoint id"))
			return
		}
		if _, err := b.Restore(body.ID); err != nil {
			failure(w, http.StatusBadRequest, err)
			return
		}
		reply(w, http.StatusOK, map[string]string{"generation": b.Generation()})
	})
	mux.Handle("/", b)
	return mux
}
