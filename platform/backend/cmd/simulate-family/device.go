package main

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
)

// The virtual device mirrors clients/ios/UnetonPackage/Sources/UnetonCore/
// SyncCoordinator.swift: a durable pending queue with one shared sequence,
// revision reservation for queued edits, an authoritative cache folded from
// results, snapshots, and events, an acknowledged journal pruned by the
// server's retention cutoff, one automatic rebase, durable conflicts,
// duplicate-start aliasing, and journal replay after a reset.

var (
	errOffline      = errors.New("device is offline")
	errLostResponse = errors.New("response lost in transit")
	errNotMember    = errors.New("family access denied")
)

type command struct {
	ID            string
	Kind          string
	Expected      *int64
	Child         *unetonv1.ChildInput
	Sleep         *unetonv1.SleepInput
	Growth        *unetonv1.GrowthMeasurementInput
	Temperature   *unetonv1.TemperatureReadingInput
	DeleteID      string
	Sequence      int64
	RebaseAttempt int
	CreatedAt     time.Time
	// AcknowledgedAt is the server time of the response that accepted it.
	AcknowledgedAt time.Time
	// Deferral mirrors PendingCommand.deferredAtCursor/deferredSince: a command
	// rejected because its target does not exist yet waits for the family
	// cursor to move past DeferredAtCursor, and becomes a conflict after a day.
	DeferredAtCursor *int64
	DeferredSince    *time.Time
	Deferrals        int
	LastError        string
}

const deferralLimit = 24 * time.Hour

// targetsExistingEntity mirrors SyncCoordinator.targetsExistingEntity.
func (c *command) targetsExistingEntity() bool {
	switch c.Kind {
	case "endSleep", "updateChild", "deleteChild", "deleteSleep", "deleteGrowthMeasurement", "deleteTemperatureReading":
		return true
	case "upsertSleep", "upsertGrowthMeasurement", "upsertTemperatureReading":
		return c.Expected != nil
	}
	return false
}

func (c *command) clone() *command {
	copy := *c
	if c.Expected != nil {
		value := *c.Expected
		copy.Expected = &value
	}
	if c.DeferredAtCursor != nil {
		value := *c.DeferredAtCursor
		copy.DeferredAtCursor = &value
	}
	if c.DeferredSince != nil {
		value := *c.DeferredSince
		copy.DeferredSince = &value
	}
	if c.Child != nil {
		copy.Child = proto.Clone(c.Child).(*unetonv1.ChildInput)
	}
	if c.Sleep != nil {
		copy.Sleep = proto.Clone(c.Sleep).(*unetonv1.SleepInput)
	}
	if c.Growth != nil {
		copy.Growth = proto.Clone(c.Growth).(*unetonv1.GrowthMeasurementInput)
	}
	if c.Temperature != nil {
		copy.Temperature = proto.Clone(c.Temperature).(*unetonv1.TemperatureReadingInput)
	}
	return &copy
}

func (c *command) identity() (string, string) {
	switch c.Kind {
	case "createChild", "updateChild":
		return "child", c.Child.GetId()
	case "deleteChild":
		return "child", c.DeleteID
	case "startSleep", "endSleep", "upsertSleep":
		return "sleepSession", c.Sleep.GetId()
	case "deleteSleep":
		return "sleepSession", c.DeleteID
	case "upsertGrowthMeasurement":
		return "growthMeasurement", c.Growth.GetId()
	case "deleteGrowthMeasurement":
		return "growthMeasurement", c.DeleteID
	case "upsertTemperatureReading":
		return "temperatureReading", c.Temperature.GetId()
	case "deleteTemperatureReading":
		return "temperatureReading", c.DeleteID
	}
	return "", ""
}

func (c *command) proto() *unetonv1.Command {
	result := &unetonv1.Command{Id: c.ID, ExpectedRevision: c.Expected}
	switch c.Kind {
	case "createChild":
		result.Payload = &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: c.Child}}
	case "updateChild":
		result.Payload = &unetonv1.Command_UpdateChild{UpdateChild: &unetonv1.UpdateChild{Child: c.Child}}
	case "deleteChild":
		result.Payload = &unetonv1.Command_DeleteChild{DeleteChild: &unetonv1.DeleteChild{Id: c.DeleteID}}
	case "startSleep":
		result.Payload = &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: c.Sleep}}
	case "endSleep":
		result.Payload = &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{
			Id: c.Sleep.GetId(), EndedAt: c.Sleep.GetEndedAt(), EndCondition: c.Sleep.GetEndCondition(),
			WakeMood: c.Sleep.GetWakeMood(), WakeReason: c.Sleep.GetWakeReason(), CaregiverIntervened: c.Sleep.CaregiverIntervened,
		}}
	case "upsertSleep":
		result.Payload = &unetonv1.Command_UpsertSleep{UpsertSleep: &unetonv1.UpsertSleep{Sleep: c.Sleep}}
	case "deleteSleep":
		result.Payload = &unetonv1.Command_DeleteSleep{DeleteSleep: &unetonv1.DeleteSleep{Id: c.DeleteID}}
	case "upsertGrowthMeasurement":
		result.Payload = &unetonv1.Command_UpsertGrowthMeasurement{UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: c.Growth}}
	case "deleteGrowthMeasurement":
		result.Payload = &unetonv1.Command_DeleteGrowthMeasurement{DeleteGrowthMeasurement: &unetonv1.DeleteGrowthMeasurement{Id: c.DeleteID}}
	case "upsertTemperatureReading":
		result.Payload = &unetonv1.Command_UpsertTemperatureReading{UpsertTemperatureReading: &unetonv1.UpsertTemperatureReading{Reading: c.Temperature}}
	case "deleteTemperatureReading":
		result.Payload = &unetonv1.Command_DeleteTemperatureReading{DeleteTemperatureReading: &unetonv1.DeleteTemperatureReading{Id: c.DeleteID}}
	}
	return result
}

// view is one row of the device's visible tables.
type view struct {
	Type, ID, ChildID string
	Revision          int64
	Deleted           bool
	SupersededBy      string
	// child
	Nickname, BirthDate, PredictionMode, TimeZone, GrowthReference string
	ManualInterval                                                 *int32
	QuietStart, QuietEnd                                           int32
	// sleep
	Start                                                                     time.Time
	End                                                                       *time.Time
	Source, StartCondition, SleepLocation, EndCondition, WakeMood, WakeReason string
	Intervened                                                                *bool
	// growth and temperature
	MeasuredAt     time.Time
	Weight, Height *int32
	Note           string
	Centi          int32
	Pending        bool
}

func key(entityType, id string) string { return entityType + ":" + id }

func viewFromEntity(entityType, id string, revision int64, operation string, entity *unetonv1.Entity) *view {
	v := &view{Type: entityType, ID: id, Revision: revision, Deleted: operation == "delete"}
	switch value := entity.GetValue().(type) {
	case *unetonv1.Entity_Child:
		c := value.Child
		v.Nickname, v.BirthDate, v.PredictionMode, v.TimeZone, v.GrowthReference = c.GetNickname(), c.GetBirthDate(), c.GetPredictionMode(), c.GetTimeZone(), c.GetGrowthReference()
		v.ManualInterval, v.QuietStart, v.QuietEnd = c.ManualIntervalMinutes, c.GetQuietHoursStartMinutes(), c.GetQuietHoursEndMinutes()
		v.Deleted = v.Deleted || c.GetDeletedAt() != nil
	case *unetonv1.Entity_SleepSession:
		s := value.SleepSession
		v.ChildID, v.Start = s.GetChildId(), s.GetStartedAt().AsTime()
		if s.EndedAt != nil {
			end := s.GetEndedAt().AsTime()
			v.End = &end
		}
		v.Source, v.StartCondition, v.SleepLocation, v.EndCondition, v.WakeMood, v.WakeReason = s.GetSource(), s.GetStartCondition(), s.GetSleepLocation(), s.GetEndCondition(), s.GetWakeMood(), s.GetWakeReason()
		v.Intervened = s.CaregiverIntervened
		v.SupersededBy = s.GetSupersededById()
		v.Deleted = v.Deleted || s.GetDeletedAt() != nil
	case *unetonv1.Entity_GrowthMeasurement:
		g := value.GrowthMeasurement
		v.ChildID, v.MeasuredAt, v.Weight, v.Height, v.Note = g.GetChildId(), g.GetMeasuredAt().AsTime(), g.WeightGrams, g.HeightMillimeters, g.GetNote()
		v.Deleted = v.Deleted || g.GetDeletedAt() != nil
	case *unetonv1.Entity_TemperatureReading:
		t := value.TemperatureReading
		v.ChildID, v.MeasuredAt, v.Centi, v.Note = t.GetChildId(), t.GetMeasuredAt().AsTime(), t.GetCentiCelsius(), t.GetNote()
		v.Deleted = v.Deleted || t.GetDeletedAt() != nil
	case *unetonv1.Entity_Deleted:
		v.Deleted = true
	}
	return v
}

func entityRevision(entity *unetonv1.Entity) (int64, bool) {
	switch value := entity.GetValue().(type) {
	case *unetonv1.Entity_Child:
		return value.Child.GetRevision(), true
	case *unetonv1.Entity_SleepSession:
		return value.SleepSession.GetRevision(), true
	case *unetonv1.Entity_GrowthMeasurement:
		return value.GrowthMeasurement.GetRevision(), true
	case *unetonv1.Entity_TemperatureReading:
		return value.TemperatureReading.GetRevision(), true
	}
	return 0, false
}

func entityTypeName(value unetonv1.EntityType) string {
	switch value {
	case unetonv1.EntityType_ENTITY_TYPE_CHILD:
		return "child"
	case unetonv1.EntityType_ENTITY_TYPE_GROWTH_MEASUREMENT:
		return "growthMeasurement"
	case unetonv1.EntityType_ENTITY_TYPE_TEMPERATURE_READING:
		return "temperatureReading"
	}
	return "sleepSession"
}

type conflict struct {
	command *command
	server  *unetonv1.Entity
	reason  string
}

type alias struct {
	localID, canonicalID string
	offset               int64
}

type device struct {
	name     string
	userName string
	id       string
	sim      *simulation
	client   unetonv1connect.UnetonServiceClient
	familyID string

	userID, storedUserID, accessToken, refreshToken string

	online     bool
	dark       bool
	denied     bool
	lastActive time.Time

	cursor       int64
	generation   string
	pending      []*command
	journal      []*command
	base         map[string]*view
	active       map[string]map[string]bool
	conflicts    []*conflict
	overlay      map[string]*view
	overlayValid bool

	maxJournal int
	wipes      int
}

func newDevice(sim *simulation, name, userName, id string) *device {
	d := &device{name: name, userName: userName, id: id, sim: sim, client: sim.client, online: true}
	d.resetLocal()
	return d
}

func (d *device) resetLocal() {
	d.cursor, d.generation = 0, ""
	d.pending, d.journal, d.conflicts = nil, nil, nil
	d.base = map[string]*view{}
	d.active = map[string]map[string]bool{}
	d.overlayValid = false
}

// --- authentication -------------------------------------------------------

func (d *device) signIn(ctx context.Context) error {
	response, err := d.client.DevelopmentAuth(ctx, connect.NewRequest(&unetonv1.DevelopmentAuthRequest{Name: d.userName, DeviceId: d.id}))
	if err != nil {
		return fmt.Errorf("%s sign in: %w", d.name, err)
	}
	auth := response.Msg.GetAuthentication()
	// SessionStore.prepareLocalData: a different account never inherits data.
	if d.storedUserID != "" && d.storedUserID != auth.GetUserId() {
		d.sim.recordWipe(d, auth.GetUserId())
		d.resetLocal()
		d.wipes++
	}
	d.userID, d.storedUserID = auth.GetUserId(), auth.GetUserId()
	d.accessToken, d.refreshToken = auth.GetAccessToken(), auth.GetRefreshToken()
	d.denied = !containsFamily(auth.GetFamilies(), d.familyID)
	return nil
}

func containsFamily(families []*unetonv1.FamilyMembership, familyID string) bool {
	for _, family := range families {
		if family.GetId() == familyID {
			return true
		}
	}
	return false
}

func (d *device) refresh(ctx context.Context) error {
	if d.refreshToken != "" {
		response, err := d.client.RefreshAuth(ctx, connect.NewRequest(&unetonv1.RefreshAuthRequest{DeviceId: d.id, RefreshToken: d.refreshToken}))
		if err == nil {
			auth := response.Msg.GetAuthentication()
			d.accessToken = auth.GetAccessToken()
			d.denied = !containsFamily(auth.GetFamilies(), d.familyID)
			return nil
		}
		if connect.CodeOf(err) != connect.CodeUnauthenticated {
			return fmt.Errorf("%s refresh: %w", d.name, err)
		}
		d.sim.stats.reauthentications++
		d.sim.logf("%s refresh token rejected; signing in again with local data kept", d.name)
	}
	d.accessToken, d.refreshToken = "", ""
	return d.signIn(ctx)
}

func authorized[T any](message *T, token string) *connect.Request[T] {
	request := connect.NewRequest(message)
	request.Header().Set("Authorization", "Bearer "+token)
	return request
}

// withAuth retries once after refreshing, the way SessionStore does.
func (d *device) withAuth(ctx context.Context, call func(token string) error) error {
	if d.accessToken == "" {
		if err := d.refresh(ctx); err != nil {
			return err
		}
	}
	err := call(d.accessToken)
	if connect.CodeOf(err) == connect.CodeUnauthenticated {
		if err := d.refresh(ctx); err != nil {
			return err
		}
		err = call(d.accessToken)
	}
	return err
}

// --- local mutations --------------------------------------------------------

func (d *device) nextSequence() int64 {
	var maximum int64
	for _, c := range d.pending {
		maximum = max(maximum, c.Sequence)
	}
	for _, c := range d.journal {
		maximum = max(maximum, c.Sequence)
	}
	return maximum + 1
}

func derefRevision(value *int64) any {
	if value == nil {
		return "none"
	}
	return *value
}

func revisionOf(v *view) any {
	if v == nil {
		return "none"
	}
	return v.Revision
}

func (d *device) enqueue(c *command) {
	if _, id := c.identity(); id == d.sim.cfg.trace {
		d.sim.logf("TRACE %s enqueue %s %s expected=%v sequence=%d", d.name, c.Kind, c.ID, derefRevision(c.Expected), d.nextSequence())
	}
	c.Sequence = d.nextSequence()
	d.pending = append(d.pending, c)
	d.overlayValid = false
	d.sim.stats.commandsQueued++
}

// pendingRevision reserves the revision a queued mutation of the same entity
// will produce; deletes never reserve one.
func (d *device) pendingRevision(entityType, id string) *int64 {
	for index := len(d.pending) - 1; index >= 0; index-- {
		c := d.pending[index]
		if strings.HasPrefix(c.Kind, "delete") {
			continue
		}
		if t, i := c.identity(); t == entityType && i == id {
			value := int64(0)
			if c.Expected != nil {
				value = *c.Expected
			}
			value++
			return &value
		}
	}
	return nil
}

func (d *device) enqueueReserving(c *command, fallback *int64) {
	entityType, id := c.identity()
	c.Expected = d.pendingRevision(entityType, id)
	if c.Expected == nil {
		c.Expected = fallback
	}
	d.enqueue(c)
}

func int64Pointer(value int64) *int64 { return &value }

func (d *device) createChild(id, nickname, birthDate string) {
	d.enqueue(&command{ID: d.sim.newID(), Kind: "createChild", CreatedAt: d.sim.clock.Now(), Child: &unetonv1.ChildInput{
		Id: id, Nickname: nickname, BirthDate: birthDate, PredictionMode: "adaptive",
		QuietHoursStartMinutes: 1200, QuietHoursEndMinutes: 360, TimeZone: "Europe/Helsinki", GrowthReference: "none",
	}})
}

func (d *device) updateChild(childID string, mutate func(*unetonv1.ChildInput)) bool {
	child := d.get(key("child", childID))
	if child == nil {
		return false
	}
	input := &unetonv1.ChildInput{
		Id: child.ID, Nickname: child.Nickname, BirthDate: child.BirthDate, PredictionMode: child.PredictionMode,
		ManualIntervalMinutes: child.ManualInterval, QuietHoursStartMinutes: child.QuietStart, QuietHoursEndMinutes: child.QuietEnd,
		TimeZone: child.TimeZone, GrowthReference: child.GrowthReference,
	}
	mutate(input)
	var fallback *int64
	if child.Revision != 0 {
		fallback = int64Pointer(child.Revision)
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "updateChild", CreatedAt: d.sim.clock.Now(), Child: input}, fallback)
	return true
}

func (d *device) startSleep(childID, sessionID string, at time.Time, source string) {
	d.enqueue(&command{ID: d.sim.newID(), Kind: "startSleep", CreatedAt: d.sim.clock.Now(), Sleep: &unetonv1.SleepInput{
		Id: sessionID, ChildId: childID, StartedAt: timestamppb.New(at), Source: source, WakeMood: "unknown", WakeReason: "unknown",
	}})
}

func (d *device) endSleep(sessionID string, at time.Time, mood, reason string) bool {
	session := d.get(key("sleepSession", sessionID))
	if session == nil || !at.After(session.Start) {
		return false
	}
	input := sleepInputFromView(session)
	input.EndedAt, input.WakeMood, input.WakeReason = timestamppb.New(at), mood, reason
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "endSleep", CreatedAt: d.sim.clock.Now(), Sleep: input}, int64Pointer(max(1, session.Revision)))
	return true
}

func (d *device) upsertSleep(childID, sessionID string, start, end time.Time) bool {
	if !end.After(start) {
		return false
	}
	input := &unetonv1.SleepInput{Id: sessionID, ChildId: childID, StartedAt: timestamppb.New(start), EndedAt: timestamppb.New(end), Source: "manual", WakeMood: "unknown", WakeReason: "unknown"}
	var fallback *int64
	if existing := d.get(key("sleepSession", sessionID)); existing != nil {
		previous := sleepInputFromView(existing)
		input.Source, input.StartCondition, input.SleepLocation, input.EndCondition = previous.Source, previous.StartCondition, previous.SleepLocation, previous.EndCondition
		input.WakeMood, input.WakeReason, input.CaregiverIntervened = previous.WakeMood, previous.WakeReason, previous.CaregiverIntervened
		fallback = int64Pointer(existing.Revision)
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "upsertSleep", CreatedAt: d.sim.clock.Now(), Sleep: input}, fallback)
	return true
}

func (d *device) deleteSleep(sessionID string) bool {
	session := d.get(key("sleepSession", sessionID))
	if session == nil {
		return false
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "deleteSleep", CreatedAt: d.sim.clock.Now(), DeleteID: sessionID}, int64Pointer(max(1, session.Revision)))
	return true
}

func (d *device) upsertGrowth(childID, id string, at time.Time, weight, height *int32) {
	var fallback *int64
	if existing := d.get(key("growthMeasurement", id)); existing != nil {
		fallback = int64Pointer(existing.Revision)
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "upsertGrowthMeasurement", CreatedAt: d.sim.clock.Now(), Growth: &unetonv1.GrowthMeasurementInput{
		Id: id, ChildId: childID, MeasuredAt: timestamppb.New(at), WeightGrams: weight, HeightMillimeters: height,
	}}, fallback)
}

func (d *device) deleteGrowth(id string) bool {
	existing := d.get(key("growthMeasurement", id))
	if existing == nil {
		return false
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "deleteGrowthMeasurement", CreatedAt: d.sim.clock.Now(), DeleteID: id}, int64Pointer(max(1, existing.Revision)))
	return true
}

func (d *device) upsertTemperature(childID, id string, at time.Time, centi int32, note string) {
	var fallback *int64
	if existing := d.get(key("temperatureReading", id)); existing != nil && existing.Revision != 0 {
		fallback = int64Pointer(existing.Revision)
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "upsertTemperatureReading", CreatedAt: d.sim.clock.Now(), Temperature: &unetonv1.TemperatureReadingInput{
		Id: id, ChildId: childID, MeasuredAt: timestamppb.New(at), CentiCelsius: centi, Note: note,
	}}, fallback)
}

func (d *device) deleteTemperature(id string) bool {
	existing := d.get(key("temperatureReading", id))
	if existing == nil {
		return false
	}
	var fallback *int64
	if existing.Revision != 0 {
		fallback = int64Pointer(existing.Revision)
	}
	d.enqueueReserving(&command{ID: d.sim.newID(), Kind: "deleteTemperatureReading", CreatedAt: d.sim.clock.Now(), DeleteID: id}, fallback)
	return true
}

func sleepInputFromView(v *view) *unetonv1.SleepInput {
	input := &unetonv1.SleepInput{
		Id: v.ID, ChildId: v.ChildID, StartedAt: timestamppb.New(v.Start), Source: v.Source,
		StartCondition: v.StartCondition, SleepLocation: v.SleepLocation, EndCondition: v.EndCondition,
		WakeMood: v.WakeMood, WakeReason: v.WakeReason, CaregiverIntervened: v.Intervened,
	}
	if v.End != nil {
		input.EndedAt = timestamppb.New(*v.End)
	}
	if input.WakeMood == "" {
		input.WakeMood = "unknown"
	}
	if input.WakeReason == "" {
		input.WakeReason = "unknown"
	}
	return input
}

// --- projection ---------------------------------------------------------------

// inTable mirrors which authoritative records Projection.rebuild materializes.
func (d *device) baseInTable(k string) *view {
	v := d.base[k]
	if v == nil || v.Deleted {
		return nil
	}
	if v.Type != "child" {
		child := d.base[key("child", v.ChildID)]
		if child == nil || child.Deleted {
			return nil
		}
	}
	return v
}

func (d *device) rebuildOverlay() {
	if d.overlayValid {
		return
	}
	overlay := map[string]*view{}
	get := func(k string) *view {
		if v, ok := overlay[k]; ok {
			return v
		}
		return d.baseInTable(k)
	}
	childVisible := func(id string) bool { return get(key("child", id)) != nil }
	for _, c := range d.pending {
		entityType, id := c.identity()
		k := key(entityType, id)
		switch c.Kind {
		case "createChild", "updateChild":
			current := get(k)
			v := &view{Type: "child", ID: id, Pending: true, Nickname: c.Child.GetNickname(), BirthDate: c.Child.GetBirthDate(),
				PredictionMode: c.Child.GetPredictionMode(), ManualInterval: c.Child.ManualIntervalMinutes, QuietStart: c.Child.GetQuietHoursStartMinutes(),
				QuietEnd: c.Child.GetQuietHoursEndMinutes(), TimeZone: c.Child.GetTimeZone(), GrowthReference: c.Child.GetGrowthReference()}
			if current != nil {
				v.Revision = current.Revision
				if v.Nickname == "" {
					v.Nickname = current.Nickname
				}
				if v.BirthDate == "" {
					v.BirthDate = current.BirthDate
				}
			}
			overlay[k] = v
		case "startSleep", "upsertSleep", "endSleep":
			if !childVisible(c.Sleep.GetChildId()) {
				continue
			}
			var v view
			if current := get(k); current != nil {
				v = *current
			} else {
				v = view{Type: "sleepSession", ID: id}
			}
			v.ChildID, v.Start = c.Sleep.GetChildId(), c.Sleep.GetStartedAt().AsTime()
			v.End = nil
			if c.Sleep.EndedAt != nil {
				end := c.Sleep.GetEndedAt().AsTime()
				v.End = &end
			}
			if c.Sleep.GetSource() != "" {
				v.Source = c.Sleep.GetSource()
			}
			v.StartCondition, v.SleepLocation, v.EndCondition = c.Sleep.GetStartCondition(), c.Sleep.GetSleepLocation(), c.Sleep.GetEndCondition()
			v.WakeMood, v.WakeReason, v.Intervened = c.Sleep.GetWakeMood(), c.Sleep.GetWakeReason(), c.Sleep.CaregiverIntervened
			v.Pending = true
			overlay[k] = &v
		case "upsertGrowthMeasurement":
			if !childVisible(c.Growth.GetChildId()) {
				continue
			}
			v := &view{Type: "growthMeasurement", ID: id, ChildID: c.Growth.GetChildId(), MeasuredAt: c.Growth.GetMeasuredAt().AsTime(), Weight: c.Growth.WeightGrams, Height: c.Growth.HeightMillimeters, Note: c.Growth.GetNote(), Pending: true}
			if current := get(k); current != nil {
				v.Revision = current.Revision
			}
			overlay[k] = v
		case "upsertTemperatureReading":
			if !childVisible(c.Temperature.GetChildId()) {
				continue
			}
			v := &view{Type: "temperatureReading", ID: id, ChildID: c.Temperature.GetChildId(), MeasuredAt: c.Temperature.GetMeasuredAt().AsTime(), Centi: c.Temperature.GetCentiCelsius(), Note: c.Temperature.GetNote(), Pending: true}
			if current := get(k); current != nil {
				v.Revision = current.Revision
			}
			overlay[k] = v
		case "deleteChild", "deleteSleep", "deleteGrowthMeasurement", "deleteTemperatureReading":
			overlay[k] = nil
		}
	}
	d.overlay, d.overlayValid = overlay, true
}

// get returns a visible table row, or nil.
func (d *device) get(k string) *view {
	d.rebuildOverlay()
	if v, ok := d.overlay[k]; ok {
		return v
	}
	return d.baseInTable(k)
}

// activeSleep is the open, visible session the UI would offer to end.
func (d *device) activeSleep(childID string) *view {
	d.rebuildOverlay()
	candidates := map[string]bool{}
	for id := range d.active[childID] {
		candidates[id] = true
	}
	for k, v := range d.overlay {
		if v != nil && v.Type == "sleepSession" {
			candidates[strings.TrimPrefix(k, "sleepSession:")] = true
		}
	}
	var best *view
	for _, id := range sortedKeys(candidates) {
		v := d.get(key("sleepSession", id))
		if v == nil || v.End != nil || v.SupersededBy != "" || v.ChildID != childID {
			continue
		}
		if best == nil || v.Start.Before(best.Start) {
			best = v
		}
	}
	return best
}

// visible is the projection the user sees: no tombstones, no superseded
// sessions, and nothing whose child is hidden.
func (d *device) visible() map[string]*view {
	d.rebuildOverlay()
	keys := map[string]bool{}
	for k := range d.base {
		keys[k] = true
	}
	for k := range d.overlay {
		keys[k] = true
	}
	result := map[string]*view{}
	for k := range keys {
		v := d.get(k)
		if v == nil || v.Deleted || v.SupersededBy != "" {
			continue
		}
		if v.Type != "child" && d.get(key("child", v.ChildID)) == nil {
			continue
		}
		result[k] = v
	}
	return result
}

func (d *device) ingest(entityType, id string, revision int64, operation string, entity *unetonv1.Entity) {
	k := key(entityType, id)
	if id == d.sim.cfg.trace {
		d.sim.logf("TRACE %s ingest %s rev=%d op=%s (cached rev %v)", d.name, k, revision, operation, revisionOf(d.base[k]))
	}
	if existing := d.base[k]; existing != nil && existing.Revision > revision {
		return
	}
	v := viewFromEntity(entityType, id, revision, operation, entity)
	d.base[k] = v
	if entityType == "sleepSession" {
		for childID, ids := range d.active {
			if ids[id] && childID != v.ChildID {
				delete(ids, id)
			}
		}
		if v.ChildID != "" {
			if d.active[v.ChildID] == nil {
				d.active[v.ChildID] = map[string]bool{}
			}
			if !v.Deleted && v.End == nil && v.SupersededBy == "" {
				d.active[v.ChildID][id] = true
			} else {
				delete(d.active[v.ChildID], id)
			}
		}
	}
	d.overlayValid = false
}

// --- synchronization ------------------------------------------------------------

func (d *device) synchronize(ctx context.Context) error {
	if !d.online || d.dark {
		return errOffline
	}
	includeCommands, passes := true, 0
	for {
		var commands []*command
		if includeCommands {
			passes++
			commands = d.sendable()
			commands = append([]*command(nil), commands[:min(100, len(commands))]...)
		}
		request := &unetonv1.SyncRequest{FamilyId: d.familyID, Cursor: d.cursor, Generation: d.generation, Limit: int32(d.sim.cfg.pageLimit)}
		for _, c := range commands {
			request.Commands = append(request.Commands, c.proto())
		}
		var response *unetonv1.SyncResponse
		err := d.withAuth(ctx, func(token string) error {
			result, err := d.client.Sync(ctx, authorized(request, token))
			if err == nil {
				response = result.Msg
			}
			return err
		})
		if connect.CodeOf(err) == connect.CodePermissionDenied {
			d.denied = true
			return errNotMember
		}
		if err != nil {
			return err
		}
		d.denied = false
		d.sim.observeResponse(d, request, response)
		if d.sim.dropResponse() {
			return errLostResponse
		}
		if err := d.validate(response, commands); err != nil {
			d.sim.fail("server response", fmt.Sprintf("%s rejected a malformed response: %v", d.name, err))
			return err
		}
		d.apply(response)
		if response.GetHasMore() {
			includeCommands = false
			continue
		}
		if len(d.sendable()) == 0 {
			return nil
		}
		if passes >= 100 {
			return fmt.Errorf("%s: incomplete synchronization after %d command passes", d.name, passes)
		}
		includeCommands = true
	}
}

func (d *device) validate(response *unetonv1.SyncResponse, commands []*command) error {
	if response.GetGeneration() == "" || response.GetNextCursor() < 0 {
		return errors.New("missing generation or negative cursor")
	}
	if response.GetResetRequired() {
		if response.Snapshot == nil || len(response.GetCommandResults()) != 0 || response.GetHasMore() {
			return errors.New("reset without a lone snapshot")
		}
	} else if (d.generation != "" && response.GetGeneration() != d.generation) || response.GetNextCursor() < d.cursor {
		return errors.New("cursor or generation moved backwards without a reset")
	}
	if response.GetHasMore() && len(response.GetEvents()) == 0 {
		return errors.New("has more without events")
	}
	previous := d.cursor
	if response.Snapshot != nil {
		previous = response.GetSnapshot().GetCursor()
		if previous > response.GetNextCursor() || (!response.GetResetRequired() && previous < d.cursor) {
			return errors.New("snapshot cursor out of bounds")
		}
	}
	for _, event := range response.GetEvents() {
		if event.GetCursor() <= previous || event.GetCursor() > response.GetNextCursor() {
			return errors.New("event cursor out of order")
		}
		previous = event.GetCursor()
	}
	if response.GetNextCursor() != previous {
		return fmt.Errorf("next cursor %d does not match last event %d", response.GetNextCursor(), previous)
	}
	sent := map[string]bool{}
	for _, c := range commands {
		sent[c.ID] = true
	}
	seen := map[string]bool{}
	for _, result := range response.GetCommandResults() {
		if !sent[result.GetId()] || seen[result.GetId()] {
			return fmt.Errorf("unexpected command result %s", result.GetId())
		}
		seen[result.GetId()] = true
		if result.GetStatus() == unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED && result.GetEntity() == nil {
			return fmt.Errorf("accepted result %s has no entity", result.GetId())
		}
	}
	if !response.GetResetRequired() && len(seen) != len(sent) {
		return fmt.Errorf("%d results for %d commands", len(seen), len(sent))
	}
	return nil
}

// sendable mirrors SyncCoordinator.sendableCommands: pending commands in
// sequence order, minus those deferred until the cursor moves past a point.
func (d *device) sendable() []*command {
	var result []*command
	for _, c := range d.pending {
		if c.DeferredAtCursor == nil || *c.DeferredAtCursor < d.cursor {
			result = append(result, c)
		}
	}
	return result
}

func (d *device) deferred() int { return len(d.deferredCommands()) }

func (d *device) deferredCommands() []*command {
	var result []*command
	for _, c := range d.pending {
		if c.DeferredAtCursor != nil && *c.DeferredAtCursor >= d.cursor {
			result = append(result, c)
		}
	}
	return result
}

func (d *device) findPending(id string) (int, *command) {
	for index, c := range d.pending {
		if c.ID == id {
			return index, c
		}
	}
	return -1, nil
}

func (d *device) removePending(id string) {
	if index, _ := d.findPending(id); index >= 0 {
		d.pending = append(d.pending[:index], d.pending[index+1:]...)
		d.overlayValid = false
	}
}

func (d *device) apply(response *unetonv1.SyncResponse) {
	before := map[string]bool{}
	for _, c := range d.pending {
		before[c.ID] = true
	}
	ackAt := response.GetServerTime().AsTime()
	previousCursor, previousGeneration := d.cursor, d.generation
	serverTime := response.GetServerTime().AsTime()
	advancedCursor := max(d.cursor, response.GetNextCursor())
	if response.GetResetRequired() {
		advancedCursor = response.GetNextCursor()
	}
	if snapshot := response.GetSnapshot(); snapshot != nil {
		if d.sim.cfg.trace != "" {
			d.sim.logf("TRACE %s applies snapshot at cursor %d (reset=%v, own cursor %d)", d.name, snapshot.GetCursor(), response.GetResetRequired(), d.cursor)
		}
		d.base = map[string]*view{}
		d.active = map[string]map[string]bool{}
		for _, entity := range snapshot.GetEntities() {
			operation := "upsert"
			if isTombstone(entity.GetEntity()) {
				operation = "delete"
			}
			d.ingest(entityTypeName(entity.GetEntityType()), entity.GetEntityId(), entity.GetRevision(), operation, entity.GetEntity())
		}
		d.sim.stats.snapshotsApplied++
	}
	if response.GetResetRequired() {
		// Cursors restart in a restored lineage; a deferral measured against the
		// old one would stall until the new cursor happened to pass it.
		for index := range d.pending {
			d.pending[index].DeferredAtCursor = nil
		}
		for _, acknowledged := range d.journal {
			replay := acknowledged.clone()
			replay.AcknowledgedAt, replay.RebaseAttempt = time.Time{}, 0
			replay.DeferredAtCursor, replay.DeferredSince, replay.Deferrals, replay.LastError = nil, nil, 0, ""
			if index, existing := d.findPending(acknowledged.ID); existing != nil {
				d.pending[index] = replay
			} else {
				d.pending = append(d.pending, replay)
			}
			before[replay.ID] = true
			d.sim.stats.journalReplays++
		}
		sort.SliceStable(d.pending, func(i, j int) bool { return d.pending[i].Sequence < d.pending[j].Sequence })
	}
	aliases := map[string]alias{}
	resolved := map[string]bool{}
	for _, result := range response.GetCommandResults() {
		_, c := d.findPending(result.GetId())
		if c == nil {
			continue
		}
		resolved[c.ID] = true
		accepted := result.GetStatus() == unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED
		entityType, localID := c.identity()
		if entity := result.GetEntity(); entity != nil {
			if revision, ok := entityRevision(entity); ok {
				id := result.GetEntityId()
				if id == "" {
					id = localID
				}
				operation := "upsert"
				if accepted && strings.HasPrefix(c.Kind, "delete") {
					operation = "delete"
				}
				d.ingest(entityType, id, revision, operation, entity)
			}
		}
		if accepted && c.Kind == "startSleep" && result.GetEntityId() != "" && result.GetEntityId() != localID {
			if revision, ok := entityRevision(result.GetEntity()); ok {
				aliases[localID] = alias{localID: localID, canonicalID: result.GetEntityId(), offset: revision - 1}
				d.sim.stats.aliases++
				d.sim.aliases[localID] = result.GetEntityId()
				d.sim.logf("%s: start %s mapped to existing active sleep %s", d.name, localID, result.GetEntityId())
			}
		}
		if !accepted {
			if redirected := redirect(c, aliases, d.sim.newID()); redirected != nil {
				d.removePending(c.ID)
				d.enqueue(redirected)
				d.sim.stats.redirects++
				continue
			}
		}
		if accepted {
			d.removePending(c.ID)
			acknowledged := c.clone()
			acknowledged.AcknowledgedAt = ackAt
			acknowledged.DeferredAtCursor, acknowledged.DeferredSince, acknowledged.Deferrals, acknowledged.LastError = nil, nil, 0, ""
			d.upsertJournal(acknowledged)
			d.sim.recordAcknowledged(d, c, result)
			continue
		}
		if result.GetEntity() == nil && c.targetsExistingEntity() && (c.DeferredSince == nil || serverTime.Sub(*c.DeferredSince) < deferralLimit) {
			// The server has no such entity yet; another device's replay may
			// still create it. Retry once the family cursor moves.
			cursor := advancedCursor
			c.DeferredAtCursor = &cursor
			if c.DeferredSince == nil {
				since := serverTime
				c.DeferredSince = &since
			}
			c.Deferrals++
			c.LastError = result.GetError()
			// The server stored the rejection under this command ID and applied
			// nothing, so the retry takes a new ID in the same sequence position.
			c.ID = d.sim.newID()
			d.overlayValid = false
			d.sim.stats.deferrals++
			d.sim.logf("%s: %s %s deferred: command %s (was %s, result entity_id=%q, stored=%s, row now:%s), %s (deferral %d)", d.name, c.Kind, localID, c.ID, result.GetId(), result.GetEntityId(), d.sim.storedResult(result.GetId()), d.sim.rowSummary(localID), result.GetError(), c.Deferrals)
			continue
		}
		d.removePending(c.ID)
		d.sim.stats.rejections++
		d.sim.logf("%s: %s %s rejected: %s (rebase attempt %d)", d.name, c.Kind, localID, result.GetError(), c.RebaseAttempt)
		switch resolution, retry := automaticResolution(result, c, d.sim.newID(), d.sim.clock.Now()); resolution {
		case "retry":
			d.enqueue(retry)
			d.sim.stats.rebases++
		case "serverWins":
			d.sim.stats.serverWins++
		default:
			d.conflicts = append(d.conflicts, &conflict{command: c, server: result.GetEntity(), reason: result.GetError()})
			d.sim.stats.conflicts++
		}
	}
	for _, c := range append([]*command(nil), d.pending...) {
		if c.DeferredSince == nil || serverTime.Sub(*c.DeferredSince) < deferralLimit {
			continue
		}
		d.removePending(c.ID)
		resolved[c.ID] = true
		d.conflicts = append(d.conflicts, &conflict{command: c, reason: c.LastError})
		d.sim.stats.conflicts++
		d.sim.stats.deferralsExpired++
		d.sim.logf("%s: deferred %s %s became a conflict after a day: %s", d.name, c.Kind, c.ID, c.LastError)
	}
	if len(aliases) > 0 {
		for index, c := range d.pending {
			if redirected := redirect(c, aliases, c.ID); redirected != nil {
				d.pending[index] = redirected
				d.sim.stats.redirects++
			}
		}
		d.overlayValid = false
	}
	baseline := d.cursor
	if response.Snapshot != nil {
		baseline = response.GetSnapshot().GetCursor()
	}
	for _, event := range response.GetEvents() {
		if event.GetCursor() <= baseline {
			continue
		}
		operation := "upsert"
		if event.GetOperation() == unetonv1.EventOperation_EVENT_OPERATION_DELETE {
			operation = "delete"
		}
		d.ingest(entityTypeName(event.GetEntityType()), event.GetEntityId(), event.GetRevision(), operation, event.GetEntity())
	}
	if response.GetResetRequired() {
		d.cursor = response.GetNextCursor()
	} else {
		d.cursor = max(d.cursor, response.GetNextCursor())
		if cutoff := response.GetJournalRetentionCutoff(); cutoff != nil {
			d.pruneJournal(cutoff.AsTime())
		}
	}
	d.generation = response.GetGeneration()
	d.maxJournal = max(d.maxJournal, len(d.journal))
	d.sim.checkCursor(d, previousGeneration, previousCursor, response.GetResetRequired())
	// Pending commands may only leave through a result for them.
	for _, c := range d.pending {
		delete(before, c.ID)
	}
	for id := range before {
		if !resolved[id] {
			d.sim.fail("pending durability", fmt.Sprintf("%s lost pending command %s without a result", d.name, id))
		}
	}
	d.overlayValid = false
}

func isTombstone(entity *unetonv1.Entity) bool {
	switch value := entity.GetValue().(type) {
	case *unetonv1.Entity_Child:
		return value.Child.GetDeletedAt() != nil
	case *unetonv1.Entity_SleepSession:
		return value.SleepSession.GetDeletedAt() != nil
	case *unetonv1.Entity_GrowthMeasurement:
		return value.GrowthMeasurement.GetDeletedAt() != nil
	case *unetonv1.Entity_TemperatureReading:
		return value.TemperatureReading.GetDeletedAt() != nil
	}
	return false
}

func (d *device) upsertJournal(c *command) {
	for index, existing := range d.journal {
		if existing.ID == c.ID {
			d.journal[index] = c
			return
		}
	}
	d.journal = append(d.journal, c)
}

func (d *device) pruneJournal(cutoff time.Time) {
	kept := d.journal[:0]
	for _, c := range d.journal {
		if c.AcknowledgedAt.Before(cutoff) {
			d.sim.stats.journalPruned++
			continue
		}
		kept = append(kept, c)
	}
	d.journal = kept
}

func redirect(c *command, aliases map[string]alias, id string) *command {
	if len(aliases) == 0 || (c.Kind != "endSleep" && c.Kind != "upsertSleep" && c.Kind != "deleteSleep") {
		return nil
	}
	_, localID := c.identity()
	target, ok := aliases[localID]
	if !ok {
		return nil
	}
	redirected := c.clone()
	redirected.ID = id
	if c.Kind == "deleteSleep" {
		redirected.DeleteID = target.canonicalID
	} else {
		redirected.Sleep.Id = target.canonicalID
	}
	if redirected.Expected != nil {
		*redirected.Expected += target.offset
	}
	return redirected
}

// automaticResolution mirrors SyncCoordinator.automaticResolution.
func automaticResolution(result *unetonv1.CommandResult, c *command, replacementID string, now time.Time) (string, *command) {
	server := result.GetEntity()
	if server == nil || c.RebaseAttempt != 0 {
		return "requiresUser", nil
	}
	revision, ok := entityRevision(server)
	if !ok {
		return "requiresUser", nil
	}
	retry := func(kind string, sleep *unetonv1.SleepInput) *command {
		replacement := c.clone()
		replacement.ID, replacement.Kind, replacement.Expected = replacementID, kind, int64Pointer(revision)
		replacement.CreatedAt, replacement.RebaseAttempt = now, 1
		if sleep != nil {
			replacement.Sleep = sleep
		}
		return replacement
	}
	switch c.Kind {
	case "deleteSleep":
		if server.GetSleepSession().GetDeletedAt() != nil {
			return "serverWins", nil
		}
	case "deleteChild":
		if server.GetChild().GetDeletedAt() != nil {
			return "serverWins", nil
		}
	case "upsertGrowthMeasurement", "deleteGrowthMeasurement", "upsertTemperatureReading", "deleteTemperatureReading", "updateChild":
	case "endSleep":
		session := server.GetSleepSession()
		if session.EndedAt == nil && session.DeletedAt == nil && session.SupersededById == nil {
			return "retry", retry("endSleep", nil)
		}
		if c.Sleep.EndedAt == nil || session.EndedAt == nil {
			return "requiresUser", nil
		}
		if !c.Sleep.GetEndedAt().AsTime().Before(session.GetEndedAt().AsTime()) {
			return "serverWins", nil
		}
		// An end before the server's start is not this session's wake.
		if !c.Sleep.GetEndedAt().AsTime().After(session.GetStartedAt().AsTime()) {
			return "requiresUser", nil
		}
		merged := &unetonv1.SleepInput{
			Id: session.GetId(), ChildId: session.GetChildId(), StartedAt: session.GetStartedAt(), EndedAt: c.Sleep.GetEndedAt(),
			Source: session.GetSource(), StartCondition: session.GetStartCondition(), SleepLocation: session.GetSleepLocation(),
			EndCondition: c.Sleep.GetEndCondition(), WakeMood: c.Sleep.GetWakeMood(), WakeReason: c.Sleep.GetWakeReason(), CaregiverIntervened: c.Sleep.CaregiverIntervened,
		}
		return "retry", retry("upsertSleep", merged)
	default:
		return "requiresUser", nil
	}
	return "retry", retry(c.Kind, nil)
}

// resolveConflicts models a caregiver opening the conflict sheet.
func (d *device) resolveConflicts(keepMine func() bool) {
	for _, item := range d.conflicts {
		if !keepMine() {
			d.sim.stats.conflictsAcceptedServer++
			if entityType, id := item.command.identity(); entityType == "sleepSession" {
				d.sim.discarded[id] = true
			}
			continue
		}
		replacement := item.command.clone()
		replacement.ID, replacement.CreatedAt, replacement.RebaseAttempt = d.sim.newID(), d.sim.clock.Now(), 1
		replacement.Expected = nil
		if revision, ok := entityRevision(item.server); ok {
			replacement.Expected = int64Pointer(revision)
		}
		d.enqueue(replacement)
		d.sim.stats.conflictsKeptMine++
	}
	d.conflicts = nil
}

func sortedKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
