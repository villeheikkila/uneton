package main

import (
	"container/heap"
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

type config struct {
	seed                uint64
	days                int
	compactionThreshold int
	faultRate           float64
	restoreHorizon      time.Duration
	journalRetention    time.Duration
	secondChildMonths   int
	freshEvery          int
	pageLimit           int
	start               time.Time
	verbose             bool
	trace               string
	keepGoing           bool
	out                 io.Writer
}

func defaultConfig() config {
	return config{
		seed: 1, days: 3 * 365, compactionThreshold: 2000, faultRate: 0.05,
		restoreHorizon: 24 * time.Hour, journalRetention: 7 * 24 * time.Hour,
		freshEvery: 30, pageLimit: 500, start: time.Date(2026, time.January, 5, 0, 0, 0, 0, time.UTC),
		out: os.Stdout,
	}
}

type stats struct {
	syncCalls, lostResponses, commandsQueued, commandsAccepted, rejections, rebases, serverWins int
	conflicts, conflictsKeptMine, conflictsAcceptedServer, aliases, redirects, journalReplays   int
	journalPruned, snapshotsApplied, compactions, restores, restarts, reauthentications, wipes  int
	eventsReceived, freshChecks, dailyChecks, reinvites, removals, offlineStretches             int
	responseBytes                                                                               []int
	maxSnapshotBytes, lastSnapshotBytes                                                         int
	maxSnapshotEntities                                                                         int
	recordedSleeps, lostSleeps                                                                  int
	deferrals, deferralsExpired, discardedSleeps, awaitingSleeps                                int
}

type scheduled struct {
	at       time.Time
	sequence int
	name     string
	run      func()
}

type queue []*scheduled

func (q queue) Len() int { return len(q) }
func (q queue) Less(i, j int) bool {
	if q[i].at.Equal(q[j].at) {
		return q[i].sequence < q[j].sequence
	}
	return q[i].at.Before(q[j].at)
}
func (q queue) Swap(i, j int)    { q[i], q[j] = q[j], q[i] }
func (q *queue) Push(x any)      { *q = append(*q, x.(*scheduled)) }
func (q *queue) Pop() any        { old := *q; item := old[len(old)-1]; *q = old[:len(old)-1]; return item }
func (q queue) peek() *scheduled { return q[0] }

type acknowledgement struct {
	device *device
	at     time.Time
	kind   string
}

type simulation struct {
	cfg      config
	ctx      context.Context
	rng      *rand.Rand
	clock    *simClock
	backend  *backend
	client   unetonv1connect.UnetonServiceClient
	location *time.Location
	dir      string

	queue    queue
	sequence int

	familyID string
	children []*childModel
	// aliases maps a local session ID to the canonical one the server chose;
	// discarded holds sessions whose conflict a caregiver resolved by
	// accepting the server version.
	aliases   map[string]string
	discarded map[string]bool
	// reportedUncovered keeps a known coverage failure from repeating daily.
	reportedUncovered int
	owner             *device
	partner           *device
	visitor           *device
	devices           []*device

	visitorMember      bool
	visitorRemoved     bool
	visitorJoined      bool
	pendingReinvite    map[*device]bool
	acknowledged       map[string]acknowledgement
	results            map[string]*unetonv1.CommandResult
	serverCursor       map[string]int64
	snapshotCursor     int64
	snapshotGeneration string
	checking           bool

	stats    stats
	log      []string
	failures []string
	day      int
}

func newSimulation(cfg config) (*simulation, error) {
	location, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp("", "uneton-simulation-")
	if err != nil {
		return nil, err
	}
	clock := newSimClock(cfg.start)
	b, err := openBackend(backendOptions{
		path: filepath.Join(dir, "uneton.sqlite"), clock: clock,
		compactionThreshold: cfg.compactionThreshold, journalRetention: cfg.journalRetention, fast: true,
	})
	if err != nil {
		return nil, err
	}
	s := &simulation{
		cfg: cfg, ctx: context.Background(), rng: rand.New(rand.NewPCG(cfg.seed, cfg.seed^0x9e3779b97f4a7c15)),
		clock: clock, backend: b, location: location, dir: dir,
		aliases: map[string]string{}, discarded: map[string]bool{},
		pendingReinvite: map[*device]bool{}, acknowledged: map[string]acknowledgement{},
		results: map[string]*unetonv1.CommandResult{}, serverCursor: map[string]int64{},
	}
	s.client = unetonv1connect.NewUnetonServiceClient(&http.Client{Transport: handlerTransport{b}}, "http://simulated.invalid")
	return s, nil
}

// handlerTransport calls the server in-process: deterministic and much faster
// than loopback TCP, while still exercising the real Connect handlers.
type handlerTransport struct{ handler http.Handler }

func (t handlerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	recorder := httptest.NewRecorder()
	t.handler.ServeHTTP(recorder, request)
	return recorder.Result(), nil
}

func (s *simulation) close() {
	s.backend.Close()
	_ = os.RemoveAll(s.dir)
}

func (s *simulation) newID() string {
	var bytes [16]byte
	for index := range bytes {
		bytes[index] = byte(s.rng.UintN(256))
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:])
}

func (s *simulation) chance(probability float64) bool { return s.rng.Float64() < probability }

func (s *simulation) schedule(at time.Time, name string, run func()) {
	s.sequence++
	heap.Push(&s.queue, &scheduled{at: at, sequence: s.sequence, name: name, run: run})
}

func (s *simulation) logf(format string, args ...any) {
	line := s.clock.Now().In(s.location).Format("2006-01-02 15:04") + " " + fmt.Sprintf(format, args...)
	s.log = append(s.log, line)
	if len(s.log) > 60 {
		s.log = s.log[len(s.log)-60:]
	}
	if s.cfg.verbose || (s.cfg.trace != "" && strings.Contains(line, "TRACE")) {
		_, _ = fmt.Fprintln(s.cfg.out, line)
	}
}

type invariantError struct{}

func (invariantError) Error() string { return "invariant failed" }

func (s *simulation) fail(invariant, detail string) {
	message := fmt.Sprintf("seed=%d day=%d time=%s invariant=%q: %s", s.cfg.seed, s.day, s.clock.Now().Format(time.RFC3339), invariant, detail)
	s.failures = append(s.failures, message)
	_, _ = fmt.Fprintln(s.cfg.out, "INVARIANT FAILURE "+message)
	if !s.cfg.keepGoing {
		panic(invariantError{})
	}
}

// --- hooks used by devices --------------------------------------------------------

func (s *simulation) dropResponse() bool {
	return !s.checking && s.chance(s.cfg.faultRate)
}

func (s *simulation) observeResponse(d *device, request *unetonv1.SyncRequest, response *unetonv1.SyncResponse) {
	s.stats.syncCalls++
	s.stats.eventsReceived += len(response.GetEvents())
	s.stats.responseBytes = append(s.stats.responseBytes, proto.Size(response))
	if snapshot := response.GetSnapshot(); snapshot != nil {
		size := proto.Size(snapshot)
		s.stats.lastSnapshotBytes = size
		s.stats.maxSnapshotBytes = max(s.stats.maxSnapshotBytes, size)
		s.stats.maxSnapshotEntities = max(s.stats.maxSnapshotEntities, len(snapshot.GetEntities()))
	}
	for _, result := range response.GetCommandResults() {
		k := response.GetGeneration() + "/" + result.GetId()
		if previous, ok := s.results[k]; ok && !sameDecision(previous, result) {
			s.fail("idempotent results", fmt.Sprintf("command %s returned %v, earlier %v", result.GetId(), result, previous))
		}
		s.results[k] = proto.Clone(result).(*unetonv1.CommandResult)
	}
	var generation string
	var cursor int64
	row := s.backend.Store().DB.QueryRowContext(s.ctx, `select generation, cursor from family_sync_snapshots where family_id=?`, s.familyID)
	if row.Scan(&generation, &cursor) == nil && (generation != s.snapshotGeneration || cursor != s.snapshotCursor) {
		if cursor > s.snapshotCursor || generation == s.snapshotGeneration {
			s.stats.compactions++
		}
		s.snapshotGeneration, s.snapshotCursor = generation, cursor
	}
}

func (s *simulation) recordAcknowledged(d *device, c *command, result *unetonv1.CommandResult) {
	s.stats.commandsAccepted++
	if _, ok := s.acknowledged[c.ID]; !ok {
		s.acknowledged[c.ID] = acknowledgement{device: d, at: s.clock.Now(), kind: c.Kind}
	}
}

func (s *simulation) recordWipe(d *device, newUserID string) {
	s.stats.wipes++
	s.logf("%s signed in as a different user %s (was %s); local data wiped with %d pending and %d journal entries", d.name, newUserID, d.storedUserID, len(d.pending), len(d.journal))
	for _, c := range d.journal {
		if entry, ok := s.acknowledged[c.ID]; ok && entry.device == d {
			entry.device = nil
			s.acknowledged[c.ID] = entry
		}
	}
	for _, c := range d.pending {
		s.logf("%s discarded unsent %s %s", d.name, c.Kind, c.ID)
	}
}

func (s *simulation) checkCursor(d *device, previousGeneration string, previousCursor int64, reset bool) {
	if d.generation == previousGeneration && d.cursor < previousCursor {
		s.fail("monotonic cursor", fmt.Sprintf("%s cursor moved from %d to %d within generation %s (reset=%v)", d.name, previousCursor, d.cursor, d.generation, reset))
	}
}

// --- running ---------------------------------------------------------------------

func (s *simulation) run() (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			if _, ok := recovered.(invariantError); ok {
				err = invariantError{}
				return
			}
			panic(recovered)
		}
	}()
	started := time.Now()
	if err := s.setup(); err != nil {
		return err
	}
	end := s.cfg.start.AddDate(0, 0, s.cfg.days)
	for day := 0; day < s.cfg.days; day++ {
		local := s.cfg.start.In(s.location).AddDate(0, 0, day)
		dayStart := localClock(local, 0, 5, s.location)
		dayIndex := day
		s.schedule(dayStart, "plan day", func() { s.day = dayIndex; s.planDay(dayIndex, local) })
		s.schedule(localClock(local, 23, 30, s.location), "daily check", func() { s.dailyCheck(dayIndex) })
	}
	for s.queue.Len() > 0 && s.queue.peek().at.Before(end) {
		item := heap.Pop(&s.queue).(*scheduled)
		at := item.at
		if at.Before(s.clock.Now()) {
			at = s.clock.Now()
		}
		if err := s.clock.Set(at); err != nil {
			return err
		}
		item.run()
	}
	_ = s.clock.Set(end)
	s.finalCheck()
	s.report(time.Since(started))
	if len(s.failures) > 0 {
		return invariantError{}
	}
	return nil
}

func (s *simulation) setup() error {
	s.checking = true
	defer func() { s.checking = false }()
	s.familyID = s.newID()
	s.owner = newDevice(s, "parent-a-phone", "Parent A", s.newID())
	s.partner = newDevice(s, "parent-b-phone", "Parent B", s.newID())
	s.visitor = newDevice(s, "grandparent-phone", "Grandparent", s.newID())
	s.devices = []*device{s.owner, s.partner, s.visitor}
	for _, d := range s.devices {
		d.familyID = s.familyID
	}
	if err := s.owner.signIn(s.ctx); err != nil {
		return err
	}
	if err := s.owner.withAuth(s.ctx, func(token string) error {
		_, err := s.client.CreateFamily(s.ctx, authorized(&unetonv1.CreateFamilyRequest{Id: s.familyID, Name: "Home"}, token))
		return err
	}); err != nil {
		return fmt.Errorf("create family: %w", err)
	}
	child := s.addChild("Baby", s.cfg.start)
	_ = child
	if err := s.join(s.partner); err != nil {
		return err
	}
	if err := s.owner.synchronize(s.ctx); err != nil {
		return fmt.Errorf("initial sync: %w", err)
	}
	if err := s.partner.synchronize(s.ctx); err != nil {
		return fmt.Errorf("partner initial sync: %w", err)
	}
	return nil
}

func (s *simulation) addChild(name string, born time.Time) *childModel {
	child := &childModel{id: s.newID(), nickname: name, born: born}
	local := born.In(s.location)
	// The first morning the model plans is the one after birth. A child added
	// mid-day would otherwise get episodes in the past, which the scheduler runs
	// immediately with the current time, so taps would not match the episode.
	child.nextWake = localClock(local, 7, 0, s.location)
	if child.nextWake.Before(born) {
		child.nextWake = localClock(local.AddDate(0, 0, 1), 7, 0, s.location)
	}
	child.nextSick = born.Add(between(s.rng, 40*24*time.Hour, 90*24*time.Hour))
	s.children = append(s.children, child)
	s.owner.createChild(child.id, name, local.Format("2006-01-02"))
	s.logf("%s added child %s", s.owner.name, name)
	return child
}

// join invites a caregiver device through the owner, then accepts.
func (s *simulation) join(d *device) error {
	if d.accessToken == "" && d.refreshToken == "" {
		if err := d.signIn(s.ctx); err != nil {
			return err
		}
	}
	var token string
	if err := s.owner.withAuth(s.ctx, func(access string) error {
		response, err := s.client.CreateInvite(s.ctx, authorized(&unetonv1.CreateInviteRequest{FamilyId: s.familyID}, access))
		if err == nil {
			token = response.Msg.GetToken()
		}
		return err
	}); err != nil {
		return fmt.Errorf("create invite: %w", err)
	}
	if err := d.withAuth(s.ctx, func(access string) error {
		_, err := s.client.AcceptInvite(s.ctx, authorized(&unetonv1.AcceptInviteRequest{Token: token}, access))
		return err
	}); err != nil {
		return fmt.Errorf("accept invite: %w", err)
	}
	d.denied = false
	s.logf("%s joined the family", d.name)
	return nil
}

func (s *simulation) shouldBeMember(d *device) bool {
	if d == s.visitor {
		return s.visitorJoined && !s.visitorRemoved
	}
	return true
}

// act runs a caregiver action the way the app does: optionally foreground
// sync, apply local intent, then sync after the action.
func (s *simulation) act(d *device, preSync bool, action func()) {
	if d.dark {
		return
	}
	d.lastActive = s.clock.Now()
	if preSync {
		s.sync(d)
	}
	action()
	s.sync(d)
}

func (s *simulation) sync(d *device) {
	err := d.synchronize(s.ctx)
	switch {
	case err == nil, errors.Is(err, errOffline):
	case errors.Is(err, errLostResponse):
		s.stats.lostResponses++
	case errors.Is(err, errNotMember):
		if s.shouldBeMember(d) && !s.pendingReinvite[d] {
			s.pendingReinvite[d] = true
			s.logf("%s lost family access unexpectedly; re-inviting", d.name)
			s.schedule(s.clock.Now().Add(between(s.rng, time.Hour, 6*time.Hour)), "re-invite", func() { s.reinvite(d) })
		}
	default:
		s.fail("sync availability", fmt.Sprintf("%s sync failed: %v", d.name, err))
	}
}

func (s *simulation) reinvite(d *device) {
	delete(s.pendingReinvite, d)
	if !s.shouldBeMember(d) {
		return
	}
	if err := s.join(d); err != nil {
		s.logf("re-invite of %s failed: %v", d.name, err)
		s.pendingReinvite[d] = true
		s.schedule(s.clock.Now().Add(time.Hour), "re-invite", func() { s.reinvite(d) })
		return
	}
	s.stats.reinvites++
	s.sync(d)
}

// --- the family's day ------------------------------------------------------------

func (s *simulation) planDay(day int, local time.Time) {
	f := s.cfg.faultRate
	if s.cfg.secondChildMonths > 0 && day == s.cfg.secondChildMonths*30 {
		at := localClock(local, 10, 0, s.location)
		s.schedule(at, "second child", func() {
			s.act(s.owner, true, func() { s.addChild("Sibling", at) })
		})
	}
	// Grandparent joins at four months and is removed for two weeks at a year.
	switch day {
	case 120:
		s.schedule(localClock(local, 12, 0, s.location), "grandparent joins", func() {
			s.visitorJoined = true
			if err := s.join(s.visitor); err != nil {
				s.fail("membership", err.Error())
			}
			s.sync(s.visitor)
		})
	case 365:
		s.schedule(localClock(local, 9, 0, s.location), "grandparent removed", func() { s.removeVisitor() })
	case 379:
		s.schedule(localClock(local, 9, 0, s.location), "grandparent re-invited", func() {
			s.visitorRemoved = false
			s.reinvite(s.visitor)
		})
	case 210:
		// Parent B stops opening the app for 38 days, with unsent work on the phone.
		s.schedule(localClock(local, 8, 0, s.location), "partner goes dark", func() {
			s.partner.online = false
			s.act(s.partner, false, func() {
				s.partner.upsertGrowth(s.children[0].id, s.newID(), s.clock.Now(), int32Pointer(weightGrams(s.children[0].ageMonths(s.clock.Now()))), nil)
			})
			s.partner.dark = true
			s.logf("%s goes dark with %d pending", s.partner.name, len(s.partner.pending))
		})
	case 248:
		s.schedule(localClock(local, 20, 0, s.location), "partner returns", func() {
			s.partner.dark, s.partner.online = false, true
			s.logf("%s opens the app again", s.partner.name)
			s.sync(s.partner)
		})
	}
	visiting := s.visitorJoined && !s.visitorRemoved && s.chance(0.12)
	for _, child := range s.children {
		if child.born.After(s.clock.Now().Add(24 * time.Hour)) {
			continue
		}
		for _, item := range planDay(s.rng, child, local, s.location) {
			if item.start.Before(s.clock.Now()) {
				// Never act out a sleep in the past: taps use the current time.
				continue
			}
			s.scheduleEpisode(day, item, visiting)
		}
		s.scheduleCare(day, local, child)
	}
	for _, d := range s.devices {
		if d == s.visitor && !visiting && s.chance(0.7) {
			continue
		}
		opens := 2 + s.rng.IntN(6)
		for range opens {
			at := localClock(local, 7, 0, s.location).Add(between(s.rng, 0, 15*time.Hour))
			device := d
			s.schedule(at, "foreground", func() { s.foreground(device) })
		}
		if s.chance(min(0.5, 3*f)) {
			start := localClock(local, 0, 0, s.location).Add(between(s.rng, 0, 20*time.Hour))
			s.scheduleOffline(d, start, between(s.rng, time.Hour, 8*time.Hour))
		}
		if s.chance(f / 2) {
			start := localClock(local, 0, 0, s.location).Add(between(s.rng, 0, 20*time.Hour))
			s.scheduleOffline(d, start, between(s.rng, 24*time.Hour, 72*time.Hour))
		}
	}
	if s.chance(f) {
		s.schedule(localClock(local, 0, 0, s.location).Add(between(s.rng, 0, 23*time.Hour)), "restart", func() {
			if err := s.backend.Restart(); err != nil {
				s.fail("restart", err.Error())
			}
			s.stats.restarts++
			s.logf("server restarted")
		})
	}
	// A restore happens tomorrow from a backup taken between one hour and the
	// restore horizon earlier. Checkpoints are only written when one is needed:
	// VACUUM INTO copies the whole database.
	if s.chance(f / 2) {
		restoreAt := localClock(local.AddDate(0, 0, 1), 0, 0, s.location).Add(between(s.rng, 0, 23*time.Hour))
		checkpointAt := restoreAt.Add(-between(s.rng, time.Hour, s.cfg.restoreHorizon))
		var id string
		s.schedule(checkpointAt, "checkpoint", func() {
			value, err := s.backend.Checkpoint()
			if err != nil {
				s.fail("checkpoint", err.Error())
			}
			id = value.id
		})
		s.schedule(restoreAt, "restore", func() { s.restore(id) })
	}
	if day > 0 && day%45 == 0 {
		at := localClock(local, 21, 0, s.location).Add(between(s.rng, 0, time.Hour))
		d := s.caregiver(false)
		child := s.children[s.rng.IntN(len(s.children))]
		s.schedule(at, "settings", func() {
			s.act(d, s.chance(0.7), func() {
				d.updateChild(child.id, func(input *unetonv1.ChildInput) {
					input.QuietHoursStartMinutes = int32(1140 + 15*s.rng.IntN(8))
					if s.chance(0.3) {
						input.GrowthReference = []string{"none", "girl", "boy"}[s.rng.IntN(3)]
					}
				})
			})
		})
	}
}

func int32Pointer(value int32) *int32 { return &value }

func (s *simulation) removeVisitor() {
	s.visitorRemoved = true
	if s.visitor.userID == "" {
		return
	}
	userID := s.visitor.userID
	err := s.owner.withAuth(s.ctx, func(token string) error {
		_, err := s.client.RemoveFamilyMember(s.ctx, authorized(&unetonv1.RemoveFamilyMemberRequest{FamilyId: s.familyID, UserId: userID}, token))
		return err
	})
	if err != nil && connect.CodeOf(err) != connect.CodeNotFound {
		s.fail("membership", fmt.Sprintf("remove grandparent: %v", err))
	}
	s.stats.removals++
	s.logf("grandparent removed from the family")
}

func (s *simulation) scheduleOffline(d *device, start time.Time, length time.Duration) {
	s.schedule(start, "offline", func() {
		if d.dark {
			return
		}
		d.online = false
		s.stats.offlineStretches++
	})
	s.schedule(start.Add(length), "online", func() {
		if d.dark {
			return
		}
		d.online = true
		s.sync(d)
	})
}

func (s *simulation) restore(id string) {
	selected, err := s.backend.Restore(id)
	if err != nil {
		s.fail("restore", err.Error())
		return
	}
	if age := s.clock.Now().Sub(selected.at); age > s.cfg.restoreHorizon {
		s.fail("restore", fmt.Sprintf("restore went back %s, beyond the %s horizon", age, s.cfg.restoreHorizon))
	}
	s.backend.PruneCheckpoints(s.cfg.restoreHorizon)
	s.stats.restores++
	if s.cfg.trace != "" {
		s.logf("TRACE restore to %s; traced row after restore:%s", selected.at.Format(time.RFC3339), s.rowSummary(s.cfg.trace))
	}
	s.logf("database restored to %s (%s old) with a new generation", selected.at.In(s.location).Format("01-02 15:04"), s.clock.Now().Sub(selected.at).Round(time.Minute))
}

// caregiver picks who is handling the baby right now.
func (s *simulation) caregiver(visiting bool) *device {
	if visiting && s.chance(0.7) {
		return s.visitor
	}
	if s.partner.dark || s.chance(0.6) {
		return s.owner
	}
	return s.partner
}

func (s *simulation) other(d *device) *device {
	if d == s.owner && !s.partner.dark {
		return s.partner
	}
	return s.owner
}

func (s *simulation) scheduleEpisode(day int, item *episode, visiting bool) {
	starter := s.caregiver(visiting && !item.night)
	if item.night {
		starter = s.owner
		if day%2 == 1 && !s.partner.dark {
			starter = s.partner
		}
	}
	ender := starter
	if !item.night && s.chance(0.2) {
		ender = s.other(starter)
	}
	child := item.child
	roll := s.rng.Float64()
	startAt := item.start.Add(between(s.rng, 0, 2*time.Minute))
	endAt := item.end.Add(between(s.rng, 0, 3*time.Minute))
	switch {
	case roll < 0.04:
		// Both phones tap start; the second has not seen the first.
		second := s.other(starter)
		s.schedule(startAt, "start", func() { s.tapStart(starter, item, true) })
		s.schedule(startAt.Add(between(s.rng, 0, time.Minute)), "racing start", func() { s.tapStart(second, item, false) })
		s.schedule(endAt, "end", func() { s.tapEnd(ender, item, endAt) })
	case roll < 0.10:
		late := endAt.Add(between(s.rng, 20*time.Minute, 2*time.Hour))
		s.schedule(startAt, "start", func() { s.tapStart(starter, item, true) })
		s.schedule(late, "late end", func() { s.tapEnd(ender, item, late) })
		if s.chance(0.7) {
			s.schedule(late.Add(between(s.rng, 30*time.Minute, 3*time.Hour)), "fix end", func() {
				s.act(ender, true, func() { s.fixInterval(ender, item, item.start, item.end) })
			})
		}
	case roll < 0.15:
		recorder := s.caregiver(visiting && !item.night)
		s.schedule(item.end.Add(between(s.rng, time.Hour, 6*time.Hour)), "manual log", func() {
			s.act(recorder, true, func() {
				if recorder.activeSleep(child.id) == nil || recorder.activeSleep(child.id).Start.After(item.end) {
					item.sessionID, item.recorder = s.newID(), recorder
					recorder.upsertSleep(child.id, item.sessionID, item.start, item.end)
				}
			})
		})
	case roll < 0.17:
		s.schedule(startAt, "start", func() { s.tapStart(starter, item, true) })
		s.schedule(endAt, "end", func() { s.tapEnd(ender, item, endAt) })
		mistaken := s.newID()
		wrongStart := item.end.Add(between(s.rng, 10*time.Minute, 50*time.Minute))
		s.schedule(endAt.Add(between(s.rng, 5*time.Minute, 30*time.Minute)), "mistaken entry", func() {
			s.act(ender, true, func() { ender.upsertSleep(child.id, mistaken, wrongStart, wrongStart.Add(5*time.Minute)) })
		})
		s.schedule(endAt.Add(between(s.rng, 40*time.Minute, 3*time.Hour)), "delete mistake", func() {
			s.act(ender, true, func() { ender.deleteSleep(mistaken) })
		})
	case roll < 0.19:
		s.schedule(startAt, "start", func() { s.tapStart(starter, item, true) })
		s.schedule(endAt, "end", func() { s.tapEnd(ender, item, endAt) })
		editor := s.caregiver(false)
		s.schedule(endAt.Add(between(s.rng, time.Hour, 24*time.Hour)), "edit start", func() {
			s.act(editor, true, func() {
				s.fixInterval(editor, item, item.start.Add(-between(s.rng, 5*time.Minute, 15*time.Minute)), item.end)
			})
		})
	default:
		s.schedule(startAt, "start", func() { s.tapStart(starter, item, s.chance(0.75)) })
		s.schedule(endAt, "end", func() { s.tapEnd(ender, item, endAt) })
	}
}

func (s *simulation) tapStart(d *device, item *episode, preSync bool) {
	s.act(d, preSync, func() {
		now := s.clock.Now()
		if active := d.activeSleep(item.child.id); active != nil {
			if now.Sub(active.Start) < 15*time.Minute {
				item.sessionID, item.recorder = active.ID, d
				return
			}
			s.endForgotten(d, active)
		}
		item.sessionID, item.recorder = s.newID(), d
		source := "phone"
		if s.chance(0.2) {
			source = "watch"
		}
		d.startSleep(item.child.id, item.sessionID, now, source)
		s.logf("%s starts sleep %s (online=%v)", d.name, item.sessionID, d.online)
	})
}

func (s *simulation) tapEnd(d *device, item *episode, at time.Time) {
	s.act(d, true, func() {
		active := d.activeSleep(item.child.id)
		if active != nil && active.Start.Before(at) {
			moods := []string{"unknown", "calm", "fussy", "crying"}
			d.endSleep(active.ID, at, moods[s.rng.IntN(len(moods))], "natural")
			s.logf("%s ends sleep %s at %s (online=%v)", d.name, active.ID, at.In(s.location).Format("15:04"), d.online)
			return
		}
		// The ender cannot see the timer (the starter's phone is offline):
		// log the sleep manually from memory.
		item.sessionID, item.recorder = s.newID(), d
		d.upsertSleep(item.child.id, item.sessionID, item.start, at)
		s.logf("%s cannot see a timer; logs sleep %s manually (online=%v)", d.name, item.sessionID, d.online)
	})
}

// fixInterval edits the session recorded for item to new times, if visible.
func (s *simulation) fixInterval(d *device, item *episode, start, end time.Time) {
	if item.sessionID == "" {
		return
	}
	session := d.get(key("sleepSession", item.sessionID))
	if session == nil || session.SupersededBy != "" || session.End == nil {
		return
	}
	d.upsertSleep(session.ChildID, session.ID, start, end)
}

// endForgotten ends a timer someone forgot, at the real wake-up if known.
func (s *simulation) endForgotten(d *device, active *view) {
	var child *childModel
	for _, candidate := range s.children {
		if candidate.id == active.ChildID {
			child = candidate
		}
	}
	end := active.Start.Add(20 * time.Minute)
	if child != nil {
		if item := child.episodeAt(active.Start); item != nil && item.end.After(active.Start) {
			end = item.end
		}
	}
	if end.After(s.clock.Now()) {
		end = s.clock.Now()
	}
	if d.endSleep(active.ID, end, "unknown", "unknown") {
		s.logf("%s ended a forgotten timer from %s", d.name, active.Start.In(s.location).Format("01-02 15:04"))
	}
}

func (s *simulation) foreground(d *device) {
	if d.dark || !d.online {
		return
	}
	s.sync(d)
	if len(d.conflicts) > 0 {
		s.act(d, false, func() { d.resolveConflicts(func() bool { return s.chance(0.2) }) })
	}
	now := s.clock.Now()
	for _, child := range s.children {
		active := d.activeSleep(child.id)
		if active == nil {
			continue
		}
		asleep := child.episodeAt(now)
		stale := now.Sub(active.Start) > 14*time.Hour || (now.Sub(active.Start) > 2*time.Hour && (asleep == nil || asleep.start.After(active.Start.Add(30*time.Minute))))
		if stale {
			s.act(d, false, func() { s.endForgotten(d, active) })
		}
	}
}

func (s *simulation) scheduleCare(day int, local time.Time, child *childModel) {
	months := child.ageMonths(localClock(local, 12, 0, s.location))
	weekly := months < 2 && local.Weekday() == time.Tuesday
	monthly := months >= 2 && local.Day() == child.born.In(s.location).Day()
	if weekly || monthly {
		at := localClock(local, 10, 0, s.location).Add(between(s.rng, 0, 6*time.Hour))
		d := s.caregiver(false)
		id := s.newID()
		s.schedule(at, "growth", func() {
			m := child.ageMonths(s.clock.Now())
			s.act(d, true, func() {
				d.upsertGrowth(child.id, id, s.clock.Now(), int32Pointer(weightGrams(m)), int32Pointer(heightMillimeters(m)))
			})
		})
		switch {
		case s.chance(0.1):
			s.schedule(at.Add(between(s.rng, time.Hour, 30*time.Hour)), "growth fix", func() {
				editor := s.caregiver(false)
				s.act(editor, true, func() {
					if existing := editor.get(key("growthMeasurement", id)); existing != nil && existing.Weight != nil {
						editor.upsertGrowth(child.id, id, existing.MeasuredAt, int32Pointer(*existing.Weight+int32(s.rng.IntN(101)-50)), existing.Height)
					}
				})
			})
		case s.chance(0.03):
			s.schedule(at.Add(between(s.rng, time.Hour, 30*time.Hour)), "growth delete", func() {
				editor := s.caregiver(false)
				s.act(editor, true, func() { editor.deleteGrowth(id) })
			})
		}
	}
	readings := 0
	if child.sick(localClock(local, 12, 0, s.location)) {
		readings = 2 + s.rng.IntN(3)
	} else if s.chance(1.0 / 30) {
		readings = 1
	}
	for range readings {
		at := localClock(local, 7, 0, s.location).Add(between(s.rng, 0, 14*time.Hour))
		d := s.caregiver(false)
		id := s.newID()
		centi := int32(3650 + s.rng.IntN(300))
		s.schedule(at, "temperature", func() {
			s.act(d, s.chance(0.7), func() { d.upsertTemperature(child.id, id, s.clock.Now(), centi, "") })
		})
		switch {
		case s.chance(0.05):
			s.schedule(at.Add(between(s.rng, 10*time.Minute, 5*time.Hour)), "temperature fix", func() {
				editor := s.caregiver(false)
				s.act(editor, true, func() {
					if existing := editor.get(key("temperatureReading", id)); existing != nil {
						editor.upsertTemperature(child.id, id, existing.MeasuredAt, existing.Centi+10, "rechecked")
					}
				})
			})
		case s.chance(0.03):
			s.schedule(at.Add(between(s.rng, 10*time.Minute, 5*time.Hour)), "temperature delete", func() {
				editor := s.caregiver(false)
				s.act(editor, true, func() { editor.deleteTemperature(id) })
			})
		}
	}
}

// --- invariants ----------------------------------------------------------------------

func (s *simulation) checkable(d *device) bool {
	return d.online && !d.dark && !d.denied && (d.accessToken != "" || d.refreshToken != "") && s.shouldBeMember(d)
}

// quiesce lets every reachable device drain and pull with faults off.
func (s *simulation) quiesce(force bool) []*device {
	s.checking = true
	defer func() { s.checking = false }()
	if force {
		for _, d := range s.devices {
			if d.dark {
				d.dark = false
			}
			d.online = true
		}
		for d := range s.pendingReinvite {
			s.reinvite(d)
		}
	}
	var checked []*device
	for _, d := range s.devices {
		if s.checkable(d) {
			checked = append(checked, d)
		}
	}
	// Sync until every device has drained and holds the server's latest cursor.
	for round := 0; round < 4; round++ {
		latest, err := s.backend.Store().Queries.LatestFamilyCursor(s.ctx, s.familyID)
		if err != nil {
			s.fail("server cursor", err.Error())
		}
		generation := s.backend.Generation()
		synced := false
		for _, d := range checked {
			if len(d.pending) > 0 || d.cursor != latest || d.generation != generation {
				s.sync(d)
				synced = true
			}
		}
		if !synced {
			break
		}
	}
	var result []*device
	for _, d := range checked {
		if !s.checkable(d) {
			continue
		}
		if sendable := len(d.sendable()); sendable > 0 {
			s.fail("quiescence", fmt.Sprintf("%s still has %d sendable commands after quiescence (%d deferred)", d.name, sendable, d.deferred()))
		}
		result = append(result, d)
	}
	return result
}

func (s *simulation) dailyCheck(day int) {
	s.stats.dailyChecks++
	devices := s.quiesce(false)
	s.verify(devices)
	if s.cfg.freshEvery > 0 && day > 0 && day%s.cfg.freshEvery == 0 {
		s.freshDeviceCheck()
	}
}

func (s *simulation) finalCheck() {
	s.day = s.cfg.days
	devices := s.quiesce(true)
	s.verify(devices)
	s.freshDeviceCheck()
	s.checkCoverage(true)
}

// checkCoverage checks effects, not just stored results: every real sleep a
// caregiver recorded at least two days ago must be covered by a visible
// server session. A sleep is excused only when a caregiver accepted the server
// version in a conflict about it, or when its record cannot have reached the
// server yet (recorder unreachable, or holding commands or conflicts).
func (s *simulation) checkCoverage(final bool) {
	truth := s.serverTruth()
	horizon := s.clock.Now().Add(-48 * time.Hour)
	var uncovered []string
	for _, child := range s.children {
		var sessions []*view
		for _, k := range sortedKeys(truth) {
			if v := truth[k]; v.Type == "sleepSession" && v.ChildID == child.id {
				sessions = append(sessions, v)
			}
		}
		sort.Slice(sessions, func(i, j int) bool { return sessions[i].Start.Before(sessions[j].Start) })
		for _, item := range child.episodes {
			if item.sessionID == "" || item.end.After(horizon) {
				continue
			}
			if final {
				s.stats.recordedSleeps++
			}
			if coveredBy(sessions, item.start, item.end) {
				continue
			}
			if s.discarded[item.sessionID] || s.discarded[s.aliases[item.sessionID]] {
				if final {
					s.stats.discardedSleeps++
				}
				continue
			}
			if r := item.recorder; r != nil && (!s.checkable(r) || len(r.pending) > 0 || len(r.conflicts) > 0) {
				if final {
					s.stats.awaitingSleeps++
				}
				continue
			}
			if final {
				s.stats.lostSleeps++
			}
			recorder := "unknown"
			if item.recorder != nil {
				recorder = item.recorder.name
			}
			uncovered = append(uncovered, fmt.Sprintf("child %s sleep %s..%s recorded by %s as %s%s", child.nickname,
				item.start.In(s.location).Format("2006-01-02 15:04"), item.end.In(s.location).Format("15:04"), recorder, item.sessionID,
				s.sessionsAround(child.id, item.start, item.end)))
		}
	}
	if len(uncovered) > 0 && (final || len(uncovered) > s.reportedUncovered) {
		s.fail("recorded sleep coverage", fmt.Sprintf("%d recorded sleeps have no visible server session and no explanation:\n  %s",
			len(uncovered), strings.Join(uncovered[max(0, len(uncovered)-5):], "\n  ")))
	}
	s.reportedUncovered = len(uncovered)
}

// checkDeferrals: after quiescence a device holds the server's latest cursor,
// so a command still deferred must be waiting for a target the server does not
// have. If the target exists, the deferral can never resolve on its own.
func (s *simulation) checkDeferrals(d *device) {
	tables := map[string]string{"child": "children", "sleepSession": "sleep_sessions", "growthMeasurement": "growth_measurements", "temperatureReading": "temperature_readings"}
	for _, c := range d.deferredCommands() {
		entityType, id := c.identity()
		var exists bool
		row := s.backend.Store().DB.QueryRowContext(s.ctx, "select exists(select 1 from "+tables[entityType]+" where family_id=? and id=?)", s.familyID, id)
		if err := row.Scan(&exists); err != nil {
			s.fail("deferral progress", err.Error())
			continue
		}
		if exists {
			var stored string
			_ = s.backend.Store().DB.QueryRowContext(s.ctx, "select result_json from commands where family_id=? and id=?", s.familyID, c.ID).Scan(&stored)
			s.fail("deferral progress", fmt.Sprintf("%s keeps deferring %s %s (command %s, %d deferrals, last error %q) although the server has %s %s; stored result for this command ID: %s",
				d.name, c.Kind, id, c.ID, c.Deferrals, c.LastError, entityType, id, stored))
		}
	}
}

// sessionsAround lists every server row of the child near an interval, with
// its recorded and presented times in local time, to diagnose coverage gaps.
func (s *simulation) sessionsAround(childID string, start, end time.Time) string {
	rows, err := s.backend.Store().DB.QueryContext(s.ctx, `select id, recorded_started_at, coalesce(recorded_ended_at, ''), started_at, coalesce(ended_at, ''),
		coalesce(superseded_by_id, ''), deleted_at is not null, revision from sleep_sessions
		where family_id=? and child_id=? and recorded_started_at < ? and coalesce(recorded_ended_at, ?) > ? order by recorded_started_at`,
		s.familyID, childID, formatSim(end.Add(6*time.Hour)), formatSim(end.Add(6*time.Hour)), formatSim(start.Add(-6*time.Hour)))
	if err != nil {
		return "\n      (rows unavailable: " + err.Error() + ")"
	}
	defer func() { _ = rows.Close() }()
	local := func(value string) string {
		if value == "" {
			return "open"
		}
		parsed, err := time.Parse(time.RFC3339Nano, value)
		if err != nil {
			return value
		}
		return parsed.In(s.location).Format("01-02 15:04:05")
	}
	var out strings.Builder
	for rows.Next() {
		var id, recordedStart, recordedEnd, presentedStart, presentedEnd, supersededBy string
		var deleted bool
		var revision int64
		if err := rows.Scan(&id, &recordedStart, &recordedEnd, &presentedStart, &presentedEnd, &supersededBy, &deleted, &revision); err != nil {
			return "\n      (scan failed: " + err.Error() + ")"
		}
		fmt.Fprintf(&out, "\n      %s rev=%d recorded %s..%s presented %s..%s superseded_by=%q deleted=%v", id, revision,
			local(recordedStart), local(recordedEnd), local(presentedStart), local(presentedEnd), supersededBy, deleted)
	}
	return out.String()
}

func (s *simulation) storedResult(commandID string) string {
	var stored string
	_ = s.backend.Store().DB.QueryRowContext(s.ctx, "select result_json from commands where family_id=? and id=?", s.familyID, commandID).Scan(&stored)
	return stored
}

func (s *simulation) rowSummary(id string) string {
	var family, child, recordedStart, recordedEnd, deleted string
	err := s.backend.Store().DB.QueryRowContext(s.ctx, `select family_id, child_id, recorded_started_at, coalesce(recorded_ended_at, 'open'), coalesce(deleted_at, '') from sleep_sessions where id=?`, id).Scan(&family, &child, &recordedStart, &recordedEnd, &deleted)
	if err != nil {
		return " " + err.Error()
	}
	_, recordErr := s.backend.Store().Queries.SleepRecord(s.ctx, storedb.SleepRecordParams{ID: id, FamilyID: family})
	return fmt.Sprintf(" family=%s (sim %s) child=%s recorded %s..%s deleted=%q SleepRecord error=%v", family, s.familyID, child, recordedStart, recordedEnd, deleted, recordErr)
}

func formatSim(value time.Time) string { return value.UTC().Format(time.RFC3339Nano) }

// coveredBy reports whether any session overlaps [start, end); an active
// session covers everything after its start.
func coveredBy(sessions []*view, start, end time.Time) bool {
	for _, v := range sessions {
		if !v.Start.Before(end) {
			return false
		}
		if v.End == nil || v.End.After(start) {
			return true
		}
	}
	return false
}

func (s *simulation) verify(devices []*device) {
	truth := s.serverTruth()
	for _, d := range devices {
		// A deferred command's optimistic overlay legitimately differs from
		// the server while it waits for its target; the deferral invariant
		// below checks that it is not waiting for something already there.
		local, server := d.visible(), truth
		if deferred := d.deferredCommands(); len(deferred) > 0 {
			server = make(map[string]*view, len(truth))
			for k, v := range truth {
				server[k] = v
			}
			for _, c := range deferred {
				entityType, id := c.identity()
				delete(local, key(entityType, id))
				delete(server, key(entityType, id))
			}
		}
		compareViews(s, d.name, local, server)
		s.checkDeferrals(d)
	}
	s.checkOverlaps(truth)
	s.checkAcknowledged(devices)
	s.checkCoverage(false)
	generation := s.backend.Generation()
	latest, err := s.backend.Store().Queries.LatestFamilyCursor(s.ctx, s.familyID)
	if err != nil {
		s.fail("server cursor", err.Error())
	}
	if previous, ok := s.serverCursor[generation]; ok && latest < previous {
		s.fail("monotonic cursor", fmt.Sprintf("server cursor went from %d to %d in generation %s", previous, latest, generation))
	}
	s.serverCursor[generation] = latest
}

// freshDeviceCheck signs in a brand new device and syncs from nothing through
// small pages, the path a new or reinstalled phone takes.
func (s *simulation) freshDeviceCheck() {
	s.stats.freshChecks++
	s.checking = true
	defer func() { s.checking = false }()
	fresh := newDevice(s, "fresh-device", s.owner.userName, s.newID())
	fresh.familyID = s.familyID
	saved := s.cfg.pageLimit
	s.cfg.pageLimit = 50
	defer func() { s.cfg.pageLimit = saved }()
	if err := fresh.signIn(s.ctx); err != nil {
		s.fail("fresh device", err.Error())
	}
	if err := fresh.synchronize(s.ctx); err != nil {
		s.fail("fresh device", err.Error())
	}
	compareViews(s, "fresh-device", fresh.visible(), s.serverTruth())
	_ = fresh.withAuth(s.ctx, func(token string) error {
		_, err := s.client.SignOut(s.ctx, authorized(&unetonv1.SignOutRequest{}, token))
		return err
	})
}

func (s *simulation) serverTruth() map[string]*view {
	db := s.backend.Store().DB
	all := map[string]*view{}
	children := map[string]bool{}
	rows, err := db.QueryContext(s.ctx, `select id, nickname, birth_date, revision, deleted_at is not null from children where family_id=?`, s.familyID)
	if err != nil {
		s.fail("server truth", err.Error())
		return all
	}
	for rows.Next() {
		v := &view{Type: "child"}
		if err := rows.Scan(&v.ID, &v.Nickname, &v.BirthDate, &v.Revision, &v.Deleted); err != nil {
			s.fail("server truth", err.Error())
		}
		if !v.Deleted {
			children[v.ID] = true
			all[key("child", v.ID)] = v
		}
	}
	_ = rows.Close()
	rows, err = db.QueryContext(s.ctx, `select id, child_id, started_at, ended_at, revision from sleep_sessions where family_id=? and deleted_at is null and superseded_by_id is null`, s.familyID)
	if err != nil {
		s.fail("server truth", err.Error())
		return all
	}
	for rows.Next() {
		v := &view{Type: "sleepSession"}
		var start string
		var end *string
		if err := rows.Scan(&v.ID, &v.ChildID, &start, &end, &v.Revision); err != nil {
			s.fail("server truth", err.Error())
		}
		v.Start, _ = time.Parse(time.RFC3339Nano, start)
		if end != nil {
			parsed, _ := time.Parse(time.RFC3339Nano, *end)
			v.End = &parsed
		}
		if children[v.ChildID] {
			all[key("sleepSession", v.ID)] = v
		}
	}
	_ = rows.Close()
	rows, err = db.QueryContext(s.ctx, `select id, child_id, measured_at, weight_grams, height_millimeters, revision from growth_measurements where family_id=? and deleted_at is null`, s.familyID)
	if err != nil {
		s.fail("server truth", err.Error())
		return all
	}
	for rows.Next() {
		v := &view{Type: "growthMeasurement"}
		var measured string
		var weight, height *int32
		if err := rows.Scan(&v.ID, &v.ChildID, &measured, &weight, &height, &v.Revision); err != nil {
			s.fail("server truth", err.Error())
		}
		v.MeasuredAt, _ = time.Parse(time.RFC3339Nano, measured)
		v.Weight, v.Height = weight, height
		if children[v.ChildID] {
			all[key("growthMeasurement", v.ID)] = v
		}
	}
	_ = rows.Close()
	rows, err = db.QueryContext(s.ctx, `select id, child_id, measured_at, centi_celsius, revision from temperature_readings where family_id=? and deleted_at is null`, s.familyID)
	if err != nil {
		s.fail("server truth", err.Error())
		return all
	}
	for rows.Next() {
		v := &view{Type: "temperatureReading"}
		var measured string
		if err := rows.Scan(&v.ID, &v.ChildID, &measured, &v.Centi, &v.Revision); err != nil {
			s.fail("server truth", err.Error())
		}
		v.MeasuredAt, _ = time.Parse(time.RFC3339Nano, measured)
		if children[v.ChildID] {
			all[key("temperatureReading", v.ID)] = v
		}
	}
	_ = rows.Close()
	return all
}

func describe(v *view) string {
	if v == nil {
		return "absent"
	}
	switch v.Type {
	case "sleepSession":
		end := "active"
		if v.End != nil {
			end = v.End.UTC().Format(time.RFC3339)
		}
		return fmt.Sprintf("sleep child=%s rev=%d %s..%s", v.ChildID, v.Revision, v.Start.UTC().Format(time.RFC3339), end)
	case "child":
		return fmt.Sprintf("child %q rev=%d", v.Nickname, v.Revision)
	case "growthMeasurement":
		return fmt.Sprintf("growth rev=%d at=%s w=%v h=%v", v.Revision, v.MeasuredAt.UTC().Format(time.RFC3339), deref(v.Weight), deref(v.Height))
	default:
		return fmt.Sprintf("temperature rev=%d at=%s c=%d", v.Revision, v.MeasuredAt.UTC().Format(time.RFC3339), v.Centi)
	}
}

func deref(value *int32) any {
	if value == nil {
		return nil
	}
	return *value
}

func sameView(a, b *view) bool {
	if a.Revision != b.Revision || a.ChildID != b.ChildID {
		return false
	}
	switch a.Type {
	case "sleepSession":
		if !a.Start.Equal(b.Start) || (a.End == nil) != (b.End == nil) {
			return false
		}
		return a.End == nil || a.End.Equal(*b.End)
	case "child":
		return a.Nickname == b.Nickname && a.BirthDate == b.BirthDate
	case "growthMeasurement":
		return a.MeasuredAt.Equal(b.MeasuredAt) && deref(a.Weight) == deref(b.Weight) && deref(a.Height) == deref(b.Height)
	default:
		return a.MeasuredAt.Equal(b.MeasuredAt) && a.Centi == b.Centi
	}
}

func compareViews(s *simulation, name string, local, truth map[string]*view) {
	var differences []string
	keys := map[string]bool{}
	for k := range local {
		keys[k] = true
	}
	for k := range truth {
		keys[k] = true
	}
	for _, k := range sortedKeys(keys) {
		a, b := local[k], truth[k]
		if a != nil && b != nil && sameView(a, b) {
			continue
		}
		differences = append(differences, fmt.Sprintf("%s: device %s, server %s", k, describe(a), describe(b)))
	}
	if len(differences) > 0 {
		shown := differences[:min(5, len(differences))]
		s.fail("convergence", fmt.Sprintf("%s differs from the server in %d entities:\n  %s", name, len(differences), strings.Join(shown, "\n  ")))
	}
}

func (s *simulation) checkOverlaps(truth map[string]*view) {
	byChild := map[string][]*view{}
	for _, k := range sortedKeys(truth) {
		if v := truth[k]; v.Type == "sleepSession" {
			byChild[v.ChildID] = append(byChild[v.ChildID], v)
		}
	}
	for _, childID := range sortedKeys(byChild) {
		sessions := byChild[childID]
		sort.SliceStable(sessions, func(i, j int) bool { return sessions[i].Start.Before(sessions[j].Start) })
		active := 0
		var reach *view
		for _, v := range sessions {
			if v.End == nil {
				active++
			}
			if reach != nil && (reach.End == nil || v.Start.Before(*reach.End)) {
				s.fail("no overlapping sleeps", fmt.Sprintf("child %s: %s overlaps %s", childID, describe(v), describe(reach)))
				return
			}
			if reach == nil || reach.End != nil && (v.End == nil || v.End.After(*reach.End)) {
				reach = v
			}
		}
		if active > 1 {
			s.fail("single active sleep", fmt.Sprintf("child %s has %d active sleeps", childID, active))
		}
	}
}

// checkAcknowledged: every command any device saw accepted must still have a
// stored result on the server, including after restores, once the device
// that holds it in its journal has synchronized.
func (s *simulation) checkAcknowledged(devices []*device) {
	reachable := map[*device]bool{}
	for _, d := range devices {
		reachable[d] = true
	}
	rows, err := s.backend.Store().DB.QueryContext(s.ctx, `select id from commands where family_id=?`, s.familyID)
	if err != nil {
		s.fail("acknowledged intent", err.Error())
		return
	}
	stored := map[string]bool{}
	for rows.Next() {
		var id string
		_ = rows.Scan(&id)
		stored[id] = true
	}
	_ = rows.Close()
	var missing []string
	for _, id := range sortedKeys(s.acknowledged) {
		entry := s.acknowledged[id]
		if stored[id] {
			continue
		}
		if entry.device != nil && !reachable[entry.device] {
			continue
		}
		owner := "a wiped device"
		if entry.device != nil {
			owner = entry.device.name
		}
		missing = append(missing, fmt.Sprintf("%s %s acknowledged by %s at %s", entry.kind, id, owner, entry.at.Format(time.RFC3339)))
	}
	if len(missing) > 0 {
		s.fail("acknowledged intent", fmt.Sprintf("%d acknowledged commands are missing from the server:\n  %s", len(missing), strings.Join(missing[:min(5, len(missing))], "\n  ")))
	}
}

// sameDecision compares stored command results. An accepted result is replayed
// byte for byte. A rejection keeps its decision, but the server attaches the
// entity as it is now, which another device may have created or changed since.
func sameDecision(previous, current *unetonv1.CommandResult) bool {
	if previous.GetStatus() == unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED {
		return proto.Equal(previous, current)
	}
	return previous.GetStatus() == current.GetStatus() && previous.GetError() == current.GetError()
}
