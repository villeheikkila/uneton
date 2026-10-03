// Command simulate-family drives the real Uneton backend with a simulated
// family over years of simulated time, checking synchronization invariants
// every simulated day. See README.md.
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/pprof"
	"sort"
	"sync"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "run":
		err = runCommand(os.Args[2:])
	case "serve":
		err = serveCommand(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		if !errors.Is(err, invariantError{}) {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: simulate-family run [flags] | serve [flags]")
}

func runCommand(args []string) error {
	cfg := defaultConfig()
	flags := flag.NewFlagSet("run", flag.ExitOnError)
	seed := flags.Uint64("seed", cfg.seed, "random seed; a failure reproduces exactly with the same seed and flags")
	years := flags.Float64("years", 3, "simulated span in years")
	families := flags.Int("families", 1, "independent families, simulated one after another with consecutive seeds")
	flags.IntVar(&cfg.compactionThreshold, "compaction-threshold", cfg.compactionThreshold, "server event count that triggers a snapshot and compaction")
	flags.Float64Var(&cfg.faultRate, "fault-rate", cfg.faultRate, "probability scale for lost responses, offline stretches, restarts, and restores")
	flags.DurationVar(&cfg.restoreHorizon, "restore-horizon", cfg.restoreHorizon, "oldest checkpoint a restore may use (Litestream retention)")
	flags.DurationVar(&cfg.journalRetention, "journal-retention", cfg.journalRetention, "server journal retention; must exceed the restore horizon")
	flags.IntVar(&cfg.secondChildMonths, "second-child-months", 0, "add a sibling this many months in (0 disables)")
	flags.IntVar(&cfg.freshEvery, "fresh-every", cfg.freshEvery, "days between full fresh-device syncs from scratch (0 disables)")
	flags.StringVar(&cfg.trace, "trace", "", "log every local event for this entity ID")
	flags.BoolVar(&cfg.verbose, "verbose", false, "print the event log")
	flags.BoolVar(&cfg.keepGoing, "keep-going", false, "record every invariant failure instead of stopping at the first")
	profile := flags.String("cpuprofile", "", "write a CPU profile to this file")
	_ = flags.Parse(args)
	if *profile != "" {
		file, err := os.Create(*profile)
		if err != nil {
			return err
		}
		defer func() { _ = file.Close() }()
		if err := pprof.StartCPUProfile(file); err != nil {
			return err
		}
		defer pprof.StopCPUProfile()
	}
	cfg.days = int(*years * 365)
	// Families are independent backends, so they run in parallel; each
	// buffers its output and prints in seed order.
	type outcome struct {
		output bytes.Buffer
		err    error
	}
	outcomes := make([]*outcome, *families)
	limit := make(chan struct{}, max(1, runtime.GOMAXPROCS(0)))
	var group sync.WaitGroup
	for index := range *families {
		outcomes[index] = &outcome{}
		familyConfig := cfg
		familyConfig.seed = *seed + uint64(index)
		if *families > 1 {
			familyConfig.out = &outcomes[index].output
		}
		group.Go(func() {
			limit <- struct{}{}
			defer func() { <-limit }()
			outcomes[index].err = simulate(familyConfig)
		})
	}
	group.Wait()
	failed := false
	for _, result := range outcomes {
		if *families > 1 {
			_, _ = os.Stdout.Write(result.output.Bytes())
		}
		if result.err != nil {
			if !errors.Is(result.err, invariantError{}) {
				return result.err
			}
			failed = true
		}
	}
	if failed {
		return invariantError{}
	}
	return nil
}

func simulate(cfg config) error {
	s, err := newSimulation(cfg)
	if err != nil {
		return err
	}
	defer s.close()
	err = s.run()
	if errors.Is(err, invariantError{}) && len(s.log) > 0 {
		fmt.Fprintf(cfg.out, "last events before failure (seed %d):\n", cfg.seed)
		for _, line := range s.log[max(0, len(s.log)-25):] {
			fmt.Fprintln(cfg.out, "  "+line)
		}
	}
	return err
}

func percentile(values []int, quantile float64) int {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]int(nil), values...)
	sort.Ints(sorted)
	return sorted[min(len(sorted)-1, int(float64(len(sorted))*quantile))]
}

func (s *simulation) report(elapsed time.Duration) {
	out := s.cfg.out
	sessions, events := 0, int64(0)
	if truth := s.serverTruth(); truth != nil {
		for _, v := range truth {
			if v.Type == "sleepSession" {
				sessions++
			}
		}
	}
	for _, cursor := range s.serverCursor {
		events += cursor
	}
	fmt.Fprintf(out, "seed %d: simulated %d days (%s to %s) in %s\n", s.cfg.seed, s.cfg.days,
		s.cfg.start.Format("2006-01-02"), s.cfg.start.AddDate(0, 0, s.cfg.days).Format("2006-01-02"), elapsed.Round(time.Millisecond))
	fmt.Fprintf(out, "  diary: %d children, %d visible sleep sessions\n", len(s.children), sessions)
	fmt.Fprintf(out, "  commands: %d queued, %d accepted (%d unique), %d rejected, %d rebased, %d server-wins, %d conflicts (%d kept mine, %d accepted server)\n",
		s.stats.commandsQueued, s.stats.commandsAccepted, len(s.acknowledged), s.stats.rejections, s.stats.rebases, s.stats.serverWins,
		s.stats.conflicts, s.stats.conflictsKeptMine, s.stats.conflictsAcceptedServer)
	fmt.Fprintf(out, "  recorded sleeps: %d; not covered at the end: %d unexplained, %d discarded by accept-server conflicts, %d awaiting a device\n",
		s.stats.recordedSleeps, s.stats.lostSleeps, s.stats.discardedSleeps, s.stats.awaitingSleeps)
	fmt.Fprintf(out, "  deferrals: %d (%d expired into conflicts); deferred now:", s.stats.deferrals, s.stats.deferralsExpired)
	for _, d := range s.devices {
		fmt.Fprintf(out, " %s %d;", d.name, d.deferred())
	}
	fmt.Fprintln(out)
	fmt.Fprintf(out, "  duplicate starts: %d aliases, %d redirected commands\n", s.stats.aliases, s.stats.redirects)
	fmt.Fprintf(out, "  sync: %d calls, %d lost responses, %d events delivered, final server cursor per generation sum %d\n", s.stats.syncCalls, s.stats.lostResponses, s.stats.eventsReceived, events)
	fmt.Fprintf(out, "  server: %d compactions, %d restarts, %d restores, %d snapshots applied by devices\n", s.stats.compactions, s.stats.restarts, s.stats.restores, s.stats.snapshotsApplied)
	fmt.Fprintf(out, "  snapshots: max %d bytes (%d entities), last %d bytes\n", s.stats.maxSnapshotBytes, s.stats.maxSnapshotEntities, s.stats.lastSnapshotBytes)
	fmt.Fprintf(out, "  sync response bytes: p50 %d, p95 %d, max %d\n", percentile(s.stats.responseBytes, 0.5), percentile(s.stats.responseBytes, 0.95), percentile(s.stats.responseBytes, 1))
	fmt.Fprintf(out, "  journal: %d replayed after resets, %d pruned;", s.stats.journalReplays, s.stats.journalPruned)
	for _, d := range s.devices {
		fmt.Fprintf(out, " %s max %d now %d;", d.name, d.maxJournal, len(d.journal))
	}
	fmt.Fprintln(out)
	fmt.Fprintf(out, "  sessions: %d re-authentications, %d local wipes, %d offline stretches, %d removals, %d re-invites\n",
		s.stats.reauthentications, s.stats.wipes, s.stats.offlineStretches, s.stats.removals, s.stats.reinvites)
	fmt.Fprintf(out, "  checks: %d daily, %d fresh-device; %d invariant failures\n", s.stats.dailyChecks, s.stats.freshChecks, len(s.failures))
}
