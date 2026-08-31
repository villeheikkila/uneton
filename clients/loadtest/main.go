package main

import (
	"context"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
)

type config struct {
	baseURL            string
	families           int
	cycles             int
	concurrency        int
	timeout            time.Duration
	thinkTime          time.Duration
	ramp               string
	scenariosPerWorker int
	maxP95             time.Duration
}

type runResult struct {
	completed int64
	failed    int64
	elapsed   time.Duration
	rpcs      int
	rpcErrors int
	p95       time.Duration
	timedOut  bool
}

type recorder struct {
	mu        sync.Mutex
	latencies map[string][]time.Duration
	failures  map[string]int
}

type scenario struct {
	client   unetonv1connect.UnetonServiceClient
	metrics  *recorder
	think    time.Duration
	cycles   int
	familyNo int
	familyID string
}

type actor struct {
	auth       *unetonv1.AuthenticationResponse
	cursor     int64
	generation string
}

func main() {
	settings := parseFlags()
	if err := validate(settings); err != nil {
		log.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	steps, err := concurrencySteps(settings)
	if err != nil {
		log.Fatal(err)
	}
	if len(steps) == 1 && settings.ramp == "" {
		result := run(ctx, settings)
		if result.failed > 0 || result.rpcErrors > 0 || result.timedOut || ctx.Err() != nil {
			os.Exit(1)
		}
		return
	}

	lastPassing := 0
	for _, concurrency := range steps {
		stage := settings
		stage.concurrency = concurrency
		stage.families = concurrency * settings.scenariosPerWorker
		fmt.Printf("\n=== ramp: concurrency=%d families=%d cycles=%d ===\n", stage.concurrency, stage.families, stage.cycles)
		result := run(ctx, stage)
		if ctx.Err() != nil {
			os.Exit(1)
		}
		if result.failed > 0 || result.rpcErrors > 0 || result.timedOut || (settings.maxP95 > 0 && result.p95 > settings.maxP95) {
			fmt.Printf("capacity boundary reached at concurrency %d (last passing concurrency: %d)\n", concurrency, lastPassing)
			return
		}
		lastPassing = concurrency
	}
	fmt.Printf("\nall ramp stages passed; capacity is above the tested maximum concurrency of %d\n", lastPassing)
}

func run(parent context.Context, settings config) runResult {
	ctx, cancel := context.WithTimeout(parent, settings.timeout)
	defer cancel()

	transport := &http.Transport{
		MaxIdleConns:        settings.concurrency * 4,
		MaxIdleConnsPerHost: settings.concurrency * 4,
		IdleConnTimeout:     90 * time.Second,
	}
	httpClient := &http.Client{Transport: transport, Timeout: 15 * time.Second}
	client := unetonv1connect.NewUnetonServiceClient(httpClient, settings.baseURL)
	metrics := newRecorder()

	startedAt := time.Now()
	jobs := make(chan int)
	var completed atomic.Int64
	var failed atomic.Int64
	var workers sync.WaitGroup
	for range settings.concurrency {
		workers.Go(func() {
			for familyNo := range jobs {
				test := scenario{client: client, metrics: metrics, think: settings.thinkTime, cycles: settings.cycles, familyNo: familyNo}
				if err := test.run(ctx); err != nil {
					failed.Add(1)
					log.Printf("family %d failed: %v", familyNo, err)
					continue
				}
				completed.Add(1)
			}
		})
	}

sendJobs:
	for familyNo := 1; familyNo <= settings.families; familyNo++ {
		select {
		case jobs <- familyNo:
		case <-ctx.Done():
			break sendJobs
		}
	}
	close(jobs)
	workers.Wait()

	elapsed := time.Since(startedAt)
	fmt.Printf("\n%d families completed, %d failed in %s (%.2f scenarios/s)\n", completed.Load(), failed.Load(), elapsed.Round(time.Millisecond), float64(completed.Load())/elapsed.Seconds())
	metrics.print()
	rpcs, rpcErrors, p95 := metrics.aggregate()
	fmt.Printf("aggregate: %d RPCs, %d errors, %.2f RPC/s, p95 %s\n", rpcs, rpcErrors, float64(rpcs)/elapsed.Seconds(), p95)
	return runResult{completed: completed.Load(), failed: failed.Load(), elapsed: elapsed, rpcs: rpcs, rpcErrors: rpcErrors, p95: p95, timedOut: ctx.Err() != nil}
}

func parseFlags() config {
	settings := config{}
	flag.StringVar(&settings.baseURL, "base-url", "http://127.0.0.1:8080", "ConnectRPC server base URL")
	flag.IntVar(&settings.families, "families", 10, "number of independent virtual families")
	flag.IntVar(&settings.cycles, "cycles", 3, "sleep cycles per family")
	flag.IntVar(&settings.concurrency, "concurrency", 4, "families exercised concurrently")
	flag.DurationVar(&settings.timeout, "timeout", 2*time.Minute, "overall run timeout")
	flag.DurationVar(&settings.thinkTime, "think-time", 0, "pause between user actions")
	flag.StringVar(&settings.ramp, "ramp-concurrency", "", "comma-separated concurrency stages; enables capacity ramp mode")
	flag.IntVar(&settings.scenariosPerWorker, "scenarios-per-worker", 4, "scenarios run by each worker at every ramp stage")
	flag.DurationVar(&settings.maxP95, "max-p95", 0, "stop a ramp after aggregate RPC p95 exceeds this duration (zero disables)")
	flag.Parse()
	return settings
}

func validate(settings config) error {
	if settings.families < 1 || settings.cycles < 1 || settings.concurrency < 1 || settings.scenariosPerWorker < 1 {
		return errors.New("families, cycles, and concurrency must all be positive")
	}
	if settings.timeout <= 0 || settings.thinkTime < 0 || settings.maxP95 < 0 {
		return errors.New("timeout must be positive and think-time cannot be negative")
	}
	return nil
}

func concurrencySteps(settings config) ([]int, error) {
	if settings.ramp == "" {
		return []int{settings.concurrency}, nil
	}
	parts := strings.Split(settings.ramp, ",")
	steps := make([]int, 0, len(parts))
	previous := 0
	for _, part := range parts {
		value, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || value <= previous {
			return nil, fmt.Errorf("ramp-concurrency must contain strictly increasing positive integers: %q", settings.ramp)
		}
		steps = append(steps, value)
		previous = value
	}
	return steps, nil
}

func (s scenario) run(ctx context.Context) error {
	owner, err := s.authenticate(ctx, fmt.Sprintf("Owner %d", s.familyNo))
	if err != nil {
		return err
	}
	caregiver, err := s.authenticate(ctx, fmt.Sprintf("Caregiver %d", s.familyNo))
	if err != nil {
		return err
	}

	familyID := newID()
	s.familyID = familyID
	childID := newID()
	if err := s.call("CreateFamily", func() error {
		request := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: fmt.Sprintf("Load family %d", s.familyNo)})
		authorize(request, owner.auth.GetAccessToken())
		_, callErr := s.client.CreateFamily(ctx, request)
		return callErr
	}); err != nil {
		return fmt.Errorf("create family: %w", err)
	}

	created, err := s.sync(ctx, owner, []*unetonv1.Command{{
		Id: newID(),
		Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{
			Id: childID, Nickname: "Muru", BirthDate: time.Now().AddDate(0, -6, 0).Format(time.DateOnly), PredictionMode: "adaptive",
		}}},
	}})
	if err != nil {
		return fmt.Errorf("create child: %w", err)
	}
	if err := accepted(created, 1); err != nil {
		return fmt.Errorf("create child result: %w", err)
	}

	var inviteToken string
	if err := s.call("CreateInvite", func() error {
		request := connect.NewRequest(&unetonv1.CreateInviteRequest{FamilyId: familyID})
		authorize(request, owner.auth.GetAccessToken())
		response, callErr := s.client.CreateInvite(ctx, request)
		if callErr == nil {
			inviteToken = response.Msg.GetToken()
		}
		return callErr
	}); err != nil {
		return fmt.Errorf("create invite: %w", err)
	}
	if err := s.call("AcceptInvite", func() error {
		request := connect.NewRequest(&unetonv1.AcceptInviteRequest{Token: inviteToken})
		authorize(request, caregiver.auth.GetAccessToken())
		_, callErr := s.client.AcceptInvite(ctx, request)
		return callErr
	}); err != nil {
		return fmt.Errorf("accept invite: %w", err)
	}
	if _, err := s.sync(ctx, caregiver, nil); err != nil {
		return fmt.Errorf("initial caregiver sync: %w", err)
	}

	baseTime := time.Now().UTC().Add(-time.Duration(s.cycles*2) * time.Hour)
	for cycle := range s.cycles {
		sessionID := newID()
		commandID := newID()
		startedAt := baseTime.Add(time.Duration(cycle*2) * time.Hour)
		startCommand := &unetonv1.Command{
			Id: commandID,
			Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: &unetonv1.SleepInput{
				Id: sessionID, ChildId: childID, StartedAt: timestamppb.New(startedAt), Source: "phone",
			}}},
		}
		caregiverChange, cancelCaregiverWatch := s.watchForChange(ctx, caregiver)
		started, syncErr := s.sync(ctx, owner, []*unetonv1.Command{startCommand})
		if syncErr != nil {
			cancelCaregiverWatch()
			return fmt.Errorf("cycle %d start: %w", cycle+1, syncErr)
		}
		if err := accepted(started, 1); err != nil {
			cancelCaregiverWatch()
			return fmt.Errorf("cycle %d start result: %w", cycle+1, err)
		}
		if watchErr := <-caregiverChange; watchErr != nil {
			cancelCaregiverWatch()
			return fmt.Errorf("cycle %d caregiver stream: %w", cycle+1, watchErr)
		}
		cancelCaregiverWatch()
		s.pause(ctx)

		// A real mobile client can lose the response and resend the same durable command.
		retry, syncErr := s.sync(ctx, owner, []*unetonv1.Command{startCommand})
		if syncErr != nil {
			return fmt.Errorf("cycle %d idempotent retry: %w", cycle+1, syncErr)
		}
		if err := accepted(retry, 1); err != nil {
			return fmt.Errorf("cycle %d retry result: %w", cycle+1, err)
		}

		pulled, syncErr := s.sync(ctx, caregiver, nil)
		if syncErr != nil {
			return fmt.Errorf("cycle %d caregiver pull: %w", cycle+1, syncErr)
		}
		revision, err := sleepRevision(pulled, sessionID)
		if err != nil {
			return fmt.Errorf("cycle %d caregiver projection: %w", cycle+1, err)
		}
		s.pause(ctx)

		endedAt := startedAt.Add(45 * time.Minute)
		ownerChange, cancelOwnerWatch := s.watchForChange(ctx, owner)
		ended, syncErr := s.sync(ctx, caregiver, []*unetonv1.Command{{
			Id:               newID(),
			ExpectedRevision: &revision,
			Payload:          &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{Id: sessionID, EndedAt: timestamppb.New(endedAt)}},
		}})
		if syncErr != nil {
			cancelOwnerWatch()
			return fmt.Errorf("cycle %d end: %w", cycle+1, syncErr)
		}
		if err := accepted(ended, 1); err != nil {
			cancelOwnerWatch()
			return fmt.Errorf("cycle %d end result: %w", cycle+1, err)
		}
		if watchErr := <-ownerChange; watchErr != nil {
			cancelOwnerWatch()
			return fmt.Errorf("cycle %d owner stream: %w", cycle+1, watchErr)
		}
		cancelOwnerWatch()
		if _, syncErr = s.sync(ctx, owner, nil); syncErr != nil {
			return fmt.Errorf("cycle %d owner reconciliation: %w", cycle+1, syncErr)
		}
	}
	return nil
}

func (s scenario) watchForChange(ctx context.Context, user *actor) (<-chan error, context.CancelFunc) {
	watchContext, cancel := context.WithTimeout(ctx, 5*time.Second)
	result := make(chan error, 1)
	afterCursor := user.cursor
	go func() {
		result <- s.call("WatchFamily", func() error {
			request := connect.NewRequest(&unetonv1.WatchFamilyRequest{FamilyId: s.familyID, AfterCursor: afterCursor, Generation: user.generation})
			authorize(request, user.auth.GetAccessToken())
			stream, err := s.client.WatchFamily(watchContext, request)
			if err != nil {
				return err
			}
			defer func() { _ = stream.Close() }()
			for stream.Receive() {
				if stream.Msg().GetResetRequired() || stream.Msg().GetGeneration() != user.generation || stream.Msg().GetCursor() > afterCursor {
					return nil
				}
			}
			if err := stream.Err(); err != nil {
				return err
			}
			return errors.New("family stream closed before an update")
		})
	}()
	return result, cancel
}

func (s scenario) authenticate(ctx context.Context, name string) (*actor, error) {
	result := &actor{}
	err := s.call("DevelopmentAuth", func() error {
		response, callErr := s.client.DevelopmentAuth(ctx, connect.NewRequest(&unetonv1.DevelopmentAuthRequest{Name: name, DeviceId: newID()}))
		if callErr == nil {
			result.auth = response.Msg.GetAuthentication()
		}
		return callErr
	})
	return result, err
}

func (s scenario) sync(ctx context.Context, user *actor, commands []*unetonv1.Command) (*unetonv1.SyncResponse, error) {
	var message *unetonv1.SyncResponse
	err := s.call("Sync", func() error {
		request := connect.NewRequest(&unetonv1.SyncRequest{
			FamilyId: s.familyID, Cursor: user.cursor, Generation: user.generation, Commands: commands,
		})
		authorize(request, user.auth.GetAccessToken())
		response, callErr := s.client.Sync(ctx, request)
		if callErr == nil {
			message = response.Msg
			user.cursor = response.Msg.GetNextCursor()
			user.generation = response.Msg.GetGeneration()
		}
		return callErr
	})
	if err != nil || message == nil || !message.GetResetRequired() {
		return message, err
	}
	return s.sync(ctx, user, commands)
}

func (s scenario) call(operation string, call func() error) error {
	startedAt := time.Now()
	err := call()
	s.metrics.record(operation, time.Since(startedAt), err)
	return err
}

func (s scenario) pause(ctx context.Context) {
	if s.think <= 0 {
		return
	}
	timer := time.NewTimer(s.think)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
	}
}

func accepted(response *unetonv1.SyncResponse, count int) error {
	if response == nil || len(response.GetCommandResults()) != count {
		return fmt.Errorf("expected %d command results", count)
	}
	for _, result := range response.GetCommandResults() {
		if result.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED {
			return fmt.Errorf("command %s rejected: %s", result.GetId(), result.GetError())
		}
	}
	return nil
}

func sleepRevision(response *unetonv1.SyncResponse, sessionID string) (int64, error) {
	for _, event := range response.GetEvents() {
		if event.GetEntityId() == sessionID && event.GetEntity().GetSleepSession() != nil {
			return event.GetEntity().GetSleepSession().GetRevision(), nil
		}
	}
	if snapshot := response.GetSnapshot(); snapshot != nil {
		for _, entity := range snapshot.GetEntities() {
			if entity.GetEntityId() == sessionID && entity.GetEntity().GetSleepSession() != nil {
				return entity.GetEntity().GetSleepSession().GetRevision(), nil
			}
		}
	}
	return 0, fmt.Errorf("sleep session %s was not present in pulled events", sessionID)
}

func authorize[T any](request *connect.Request[T], token string) {
	request.Header().Set("Authorization", "Bearer "+token)
}

func newID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16])
}

func newRecorder() *recorder {
	return &recorder{latencies: make(map[string][]time.Duration), failures: make(map[string]int)}
}

func (r *recorder) record(operation string, latency time.Duration, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.latencies[operation] = append(r.latencies[operation], latency)
	if err != nil {
		r.failures[operation]++
	}
}

func (r *recorder) print() {
	r.mu.Lock()
	defer r.mu.Unlock()
	operations := make([]string, 0, len(r.latencies))
	for operation := range r.latencies {
		operations = append(operations, operation)
	}
	sort.Strings(operations)
	fmt.Println("operation          calls  errors      p50      p95      p99")
	for _, operation := range operations {
		values := append([]time.Duration(nil), r.latencies[operation]...)
		slices.Sort(values)
		fmt.Printf("%-17s %5d  %6d  %7s  %7s  %7s\n", operation, len(values), r.failures[operation], percentile(values, 0.50), percentile(values, 0.95), percentile(values, 0.99))
	}
}

func (r *recorder) aggregate() (calls int, failures int, p95 time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	values := make([]time.Duration, 0)
	for operation, operationValues := range r.latencies {
		values = append(values, operationValues...)
		calls += len(operationValues)
		failures += r.failures[operation]
	}
	slices.Sort(values)
	return calls, failures, percentile(values, 0.95)
}

func percentile(values []time.Duration, quantile float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	index := int(math.Ceil(float64(len(values))*quantile)) - 1
	index = max(0, min(index, len(values)-1))
	return values[index].Round(time.Microsecond)
}
