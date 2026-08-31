package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func (s *Server) DevelopmentAuth(ctx context.Context, req *connect.Request[unetonv1.DevelopmentAuthRequest]) (*connect.Response[unetonv1.DevelopmentAuthResponse], error) {
	if !s.development {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("development sign-in is disabled"))
	}
	name := strings.TrimSpace(req.Msg.GetName())
	if name == "" {
		return nil, invalidArgument("name is required")
	}
	deviceID := req.Msg.GetDeviceId()
	if deviceID == "" {
		deviceID = newID()
	}
	authentication, err := s.authenticateSubject(ctx, "development:"+strings.ToLower(name), name, deviceID, nil)
	if err != nil {
		return nil, internalError("could not create development user", err)
	}
	return connect.NewResponse(&unetonv1.DevelopmentAuthResponse{Authentication: authentication}), nil
}

func (s *Server) AppleAuth(ctx context.Context, req *connect.Request[unetonv1.AppleAuthRequest]) (*connect.Response[unetonv1.AppleAuthResponse], error) {
	if s.apple == nil {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("apple sign in is not configured"))
	}
	if req.Msg.GetAuthorizationCode() == "" || req.Msg.GetNonce() == "" || req.Msg.GetDeviceId() == "" {
		return nil, invalidArgument("authorization code, nonce, and device id are required")
	}
	identity, err := s.apple.subject(ctx, req.Msg.GetAuthorizationCode(), req.Msg.GetNonce())
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("apple authorization failed"))
	}
	var encryptedRefreshToken []byte
	if identity.RefreshToken != "" {
		if s.appleTokenKeys == nil {
			return nil, internalError("Apple credential encryption is unavailable", errors.New("missing token keyring"))
		}
		encryptedRefreshToken, err = s.appleTokenKeys.seal(identity.RefreshToken)
		if err != nil {
			return nil, internalError("could not protect Apple credentials", err)
		}
	}
	authentication, err := s.authenticateSubject(ctx, identity.Subject, req.Msg.GetDisplayName(), req.Msg.GetDeviceId(), encryptedRefreshToken)
	if err != nil {
		return nil, internalError("could not create account", err)
	}
	return connect.NewResponse(&unetonv1.AppleAuthResponse{Authentication: authentication}), nil
}

func (s *Server) SignOut(ctx context.Context, req *connect.Request[unetonv1.SignOutRequest]) (*connect.Response[unetonv1.SignOutResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	rows, err := s.store.Queries.DeleteDeviceForUser(ctx, storedb.DeleteDeviceForUserParams{ID: p.DeviceID, UserID: p.UserID})
	if err != nil {
		return nil, internalError("could not revoke device session", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("device session not found"))
	}
	return connect.NewResponse(&unetonv1.SignOutResponse{}), nil
}

func (s *Server) DeleteAccount(ctx context.Context, req *connect.Request[unetonv1.DeleteAccountRequest]) (*connect.Response[unetonv1.DeleteAccountResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	encryptedRefreshToken, err := s.store.Queries.UserAppleRefreshToken(ctx, p.UserID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, internalError("could not read account", err)
	}
	var appleRefreshToken string
	if len(encryptedRefreshToken) > 0 {
		if s.apple == nil {
			s.logger.WarnContext(ctx, "Apple authorization cannot be revoked after account erasure", "reason", "apple integration unavailable")
		} else if s.appleTokenKeys == nil {
			s.logger.WarnContext(ctx, "Apple authorization cannot be revoked after account erasure", "reason", "token keyring unavailable")
		} else {
			var decryptErr error
			appleRefreshToken, _, decryptErr = s.appleTokenKeys.open(encryptedRefreshToken)
			if decryptErr != nil {
				s.logger.WarnContext(ctx, "Apple authorization cannot be revoked after account erasure", "error", decryptErr)
			}
		}
	}
	if err := s.eraseAccount(ctx, p.UserID); err != nil {
		return nil, internalError("could not delete account", err)
	}
	if appleRefreshToken != "" {
		if revokeErr := s.apple.revoke(ctx, appleRefreshToken); revokeErr != nil {
			s.logger.WarnContext(ctx, "Apple authorization could not be revoked after account erasure", "error", revokeErr)
		}
	}
	return connect.NewResponse(&unetonv1.DeleteAccountResponse{}), nil
}

func (s *Server) UpdateDevicePushSettings(ctx context.Context, req *connect.Request[unetonv1.UpdateDevicePushSettingsRequest]) (*connect.Response[unetonv1.UpdateDevicePushSettingsResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	current, err := s.store.Queries.DevicePushSettings(ctx, storedb.DevicePushSettingsParams{ID: p.DeviceID, UserID: p.UserID})
	if err != nil {
		return nil, internalError("could not read device settings", err)
	}
	environment := req.Msg.GetApnsEnvironment()
	if environment == "" {
		environment = current.ApnsEnvironment
	}
	if environment != "development" && environment != "production" {
		return nil, invalidArgument("APNs environment must be development or production")
	}
	apnsToken, pushToStartToken := current.ApnsToken, current.PushToStartToken
	if req.Msg.ApnsToken != nil {
		if value := req.Msg.GetApnsToken(); value != "" && !validPushToken(value) {
			return nil, invalidArgument("invalid APNs token")
		}
		apnsToken = nullString(req.Msg.GetApnsToken())
	}
	if req.Msg.PushToStartToken != nil {
		if value := req.Msg.GetPushToStartToken(); value != "" && !validPushToken(value) {
			return nil, invalidArgument("invalid push-to-start token")
		}
		pushToStartToken = nullString(req.Msg.GetPushToStartToken())
	}
	notificationsEnabled := current.NotificationsEnabled
	if req.Msg.NotificationsEnabled != nil {
		notificationsEnabled = boolInt(req.Msg.GetNotificationsEnabled())
	}
	liveActivitiesEnabled := current.LiveActivitiesEnabled
	if req.Msg.LiveActivitiesEnabled != nil {
		liveActivitiesEnabled = boolInt(req.Msg.GetLiveActivitiesEnabled())
	}
	reminderLead := current.ReminderLeadMinutes
	if req.Msg.ReminderLeadMinutes != nil {
		reminderLead = int64(req.Msg.GetReminderLeadMinutes())
	}
	if reminderLead < 0 || reminderLead > 1440 {
		return nil, invalidArgument("reminder lead must be between 0 and 1440 minutes")
	}
	rows, err := s.store.Queries.UpdateDevicePushSettings(ctx, storedb.UpdateDevicePushSettingsParams{
		ApnsToken: apnsToken, PushToStartToken: pushToStartToken, ApnsEnvironment: environment,
		NotificationsEnabled: notificationsEnabled, LiveActivitiesEnabled: liveActivitiesEnabled,
		ReminderLeadMinutes: reminderLead, LastSeenAt: formatTime(s.now().UTC()), ID: p.DeviceID, UserID: p.UserID,
	})
	if err != nil || rows != 1 {
		return nil, internalError("could not update device settings", err)
	}
	if liveActivitiesEnabled == 1 && pushToStartToken.Valid {
		go s.startMissingLiveActivities(p.DeviceID)
	}
	return connect.NewResponse(&unetonv1.UpdateDevicePushSettingsResponse{Settings: &unetonv1.DevicePushSettings{
		NotificationsEnabled: notificationsEnabled == 1, LiveActivitiesEnabled: liveActivitiesEnabled == 1, ReminderLeadMinutes: int32(reminderLead),
	}}), nil
}

func (s *Server) RegisterLiveActivity(ctx context.Context, req *connect.Request[unetonv1.RegisterLiveActivityRequest]) (*connect.Response[unetonv1.RegisterLiveActivityResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	if req.Msg.GetSessionId() == "" || !validPushToken(req.Msg.GetPushToken()) {
		return nil, invalidArgument("session and push token are required")
	}
	environment := req.Msg.GetApnsEnvironment()
	if environment != "development" && environment != "production" {
		return nil, invalidArgument("APNs environment must be development or production")
	}
	allowed, err := s.store.Queries.CanRegisterLiveActivity(ctx, storedb.CanRegisterLiveActivityParams{SessionID: req.Msg.GetSessionId(), UserID: p.UserID})
	if err != nil {
		return nil, internalError("could not authorize live activity", err)
	}
	if !allowed {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("family access required"))
	}
	if err := s.store.Queries.RegisterLiveActivity(ctx, storedb.RegisterLiveActivityParams{SessionID: req.Msg.GetSessionId(), DeviceID: p.DeviceID, Token: req.Msg.GetPushToken(), ApnsEnvironment: environment, UpdatedAt: formatTime(s.now().UTC())}); err != nil {
		return nil, internalError("could not register live activity", err)
	}
	if _, err := s.store.Queries.ClaimLiveActivityStart(ctx, storedb.ClaimLiveActivityStartParams{
		SessionID: req.Msg.GetSessionId(), DeviceID: p.DeviceID,
		PushToStartToken: "activity:" + req.Msg.GetPushToken(), CreatedAt: formatTime(s.now().UTC()),
	}); err != nil {
		return nil, internalError("could not record live activity", err)
	}
	return connect.NewResponse(&unetonv1.RegisterLiveActivityResponse{}), nil
}

func (s *Server) RefreshAuth(ctx context.Context, req *connect.Request[unetonv1.RefreshAuthRequest]) (*connect.Response[unetonv1.RefreshAuthResponse], error) {
	if req.Msg.GetDeviceId() == "" || req.Msg.GetRefreshToken() == "" {
		return nil, invalidArgument("device and refresh token are required")
	}
	stored, err := s.store.Queries.DeviceSession(ctx, req.Msg.GetDeviceId())
	if err != nil || !authenticateRefresh(stored.RefreshTokenHash, stored.RefreshExpiresAt, req.Msg.GetRefreshToken(), s.now()) {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid refresh token"))
	}
	now := s.now().UTC()
	rows, err := s.store.Queries.TouchDeviceSession(ctx, storedb.TouchDeviceSessionParams{
		RefreshExpiresAt: nullString(formatTime(now.Add(30 * 24 * time.Hour))),
		LastSeenAt:       formatTime(now), ID: req.Msg.GetDeviceId(),
		RefreshTokenHash: stored.RefreshTokenHash,
	})
	if err != nil {
		return nil, internalError("could not refresh session", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid refresh token"))
	}
	accessToken, err := signToken(s.tokenSecret, stored.UserID, req.Msg.GetDeviceId(), now.Add(15*time.Minute))
	if err != nil {
		return nil, internalError("could not issue access token", err)
	}
	authentication, err := s.authenticationResponse(ctx, stored.UserID, req.Msg.GetDeviceId(), accessToken, req.Msg.GetRefreshToken())
	if err != nil {
		return nil, internalError("could not read family memberships", err)
	}
	return connect.NewResponse(&unetonv1.RefreshAuthResponse{Authentication: authentication}), nil
}

func (s *Server) authenticateSubject(ctx context.Context, subject, displayName, deviceID string, appleRefreshToken []byte) (*unetonv1.AuthenticationResponse, error) {
	now := s.now().UTC()
	userID, err := s.store.Queries.UserIDByAppleSubject(ctx, subject)
	if errors.Is(err, sql.ErrNoRows) {
		userID = newID()
		err = s.store.Queries.CreateUser(ctx, storedb.CreateUserParams{ID: userID, AppleSubject: subject, DisplayName: displayName, AppleRefreshTokenCiphertext: appleRefreshToken, CreatedAt: formatTime(now)})
	}
	if err != nil {
		return nil, err
	}
	if len(appleRefreshToken) > 0 {
		if err := s.store.Queries.UpdateAppleRefreshToken(ctx, storedb.UpdateAppleRefreshTokenParams{ID: userID, AppleRefreshTokenCiphertext: appleRefreshToken}); err != nil {
			return nil, err
		}
	}
	refreshToken := randomToken()
	err = s.store.Queries.UpsertDevice(ctx, storedb.UpsertDeviceParams{
		ID: deviceID, UserID: userID, RefreshTokenHash: hashToken(refreshToken),
		RefreshExpiresAt: nullString(formatTime(now.Add(30 * 24 * time.Hour))), LastSeenAt: formatTime(now),
	})
	if err != nil {
		return nil, err
	}
	accessToken, err := signToken(s.tokenSecret, userID, deviceID, now.Add(15*time.Minute))
	if err != nil {
		return nil, err
	}
	return s.authenticationResponse(ctx, userID, deviceID, accessToken, refreshToken)
}

func (s *Server) authenticationResponse(ctx context.Context, userID, deviceID, accessToken, refreshToken string) (*unetonv1.AuthenticationResponse, error) {
	rows, err := s.store.Queries.FamiliesForUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	families := make([]*unetonv1.FamilyMembership, 0, len(rows))
	for _, row := range rows {
		families = append(families, &unetonv1.FamilyMembership{Id: row.ID, Name: row.Name, Role: row.Role})
	}
	return &unetonv1.AuthenticationResponse{
		UserId: userID, DeviceId: deviceID, AccessToken: accessToken,
		RefreshToken: refreshToken, Families: families,
	}, nil
}

func (s *Server) CreateFamily(ctx context.Context, req *connect.Request[unetonv1.CreateFamilyRequest]) (*connect.Response[unetonv1.CreateFamilyResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	id := req.Msg.GetId()
	if id == "" {
		id = newID()
	}
	name := req.Msg.GetName()
	if name == "" {
		name = "Family"
	}
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, internalError("database unavailable", err)
	}
	defer func() { _ = tx.Rollback() }()
	q := s.store.Queries.WithTx(tx)
	now := formatTime(s.now().UTC())
	existing, lookupErr := q.FamilyByID(ctx, id)
	if lookupErr == nil {
		if existing.OwnerID == p.UserID {
			return connect.NewResponse(&unetonv1.CreateFamilyResponse{Id: existing.ID, Name: existing.Name, Role: "owner"}), nil
		}
		return nil, connect.NewError(connect.CodeAlreadyExists, errors.New("family identifier is already in use"))
	}
	if !errors.Is(lookupErr, sql.ErrNoRows) {
		return nil, internalError("could not create family", lookupErr)
	}
	if err = q.CreateFamily(ctx, storedb.CreateFamilyParams{ID: id, Name: name, OwnerID: p.UserID, CreatedAt: now}); err == nil {
		err = q.AddOwner(ctx, storedb.AddOwnerParams{FamilyID: id, UserID: p.UserID, JoinedAt: now})
	}
	if err != nil {
		return nil, connect.NewError(connect.CodeAlreadyExists, errors.New("could not create family"))
	}
	if err = tx.Commit(); err != nil {
		return nil, internalError("could not create family", err)
	}
	return connect.NewResponse(&unetonv1.CreateFamilyResponse{Id: id, Name: name, Role: "owner"}), nil
}

func (s *Server) CreateInvite(ctx context.Context, req *connect.Request[unetonv1.CreateInviteRequest]) (*connect.Response[unetonv1.CreateInviteResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	familyID := req.Msg.GetFamilyId()
	if !s.hasRole(ctx, familyID, p.UserID, "owner") {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("owner access required"))
	}
	token := randomToken()
	now := s.now().UTC()
	err = s.store.Queries.CreateInvite(ctx, storedb.CreateInviteParams{ID: newID(), FamilyID: familyID, TokenHash: hashToken(token), CreatedBy: p.UserID, ExpiresAt: formatTime(now.Add(7 * 24 * time.Hour)), CreatedAt: formatTime(now)})
	if err != nil {
		return nil, internalError("could not create invite", err)
	}
	return connect.NewResponse(&unetonv1.CreateInviteResponse{Token: token, ExpiresAt: timestamppb.New(now.Add(7 * 24 * time.Hour))}), nil
}

func (s *Server) AcceptInvite(ctx context.Context, req *connect.Request[unetonv1.AcceptInviteRequest]) (*connect.Response[unetonv1.AcceptInviteResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	now := s.now().UTC()
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, internalError("database unavailable", err)
	}
	defer func() { _ = tx.Rollback() }()
	q := s.store.Queries.WithTx(tx)
	invite, err := q.InviteByTokenHash(ctx, hashToken(req.Msg.GetToken()))
	if err == nil && invite.ClaimedAt.Valid {
		if invite.ClaimedBy.Valid && invite.ClaimedBy.String == p.UserID {
			return connect.NewResponse(&unetonv1.AcceptInviteResponse{FamilyId: invite.FamilyID, Role: "caregiver"}), nil
		}
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("invite is invalid or expired"))
	}
	expiresAt, parseErr := parseTime(invite.ExpiresAt)
	if err != nil || parseErr != nil || !expiresAt.After(now) {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("invite is invalid or expired"))
	}
	if err = q.AddCaregiver(ctx, storedb.AddCaregiverParams{FamilyID: invite.FamilyID, UserID: p.UserID, JoinedAt: formatTime(now)}); err == nil {
		var rows int64
		rows, err = q.ClaimInvite(ctx, storedb.ClaimInviteParams{ClaimedBy: nullString(p.UserID), ClaimedAt: nullString(formatTime(now)), ID: invite.ID})
		if err == nil && rows != 1 {
			err = errors.New("invite was already claimed")
		}
	}
	if err != nil {
		return nil, internalError("could not accept invite", err)
	}
	if err = tx.Commit(); err != nil {
		return nil, internalError("could not accept invite", err)
	}
	return connect.NewResponse(&unetonv1.AcceptInviteResponse{FamilyId: invite.FamilyID, Role: "caregiver"}), nil
}

func (s *Server) Sync(ctx context.Context, req *connect.Request[unetonv1.SyncRequest]) (*connect.Response[unetonv1.SyncResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	familyID := req.Msg.GetFamilyId()
	if !s.isMember(ctx, familyID, p.UserID) {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("family access required"))
	}
	if len(req.Msg.GetCommands()) > 100 {
		return nil, connect.NewError(connect.CodeResourceExhausted, errors.New("at most 100 commands are allowed per sync"))
	}
	request, commandKinds, err := syncRequestFromProto(req.Msg)
	if err != nil {
		return nil, invalidArgument(err.Error())
	}
	request.DeviceID = p.DeviceID
	response, err := s.synchronize(ctx, familyID, p.UserID, request)
	if err != nil {
		return nil, internalError("could not synchronize", err)
	}
	return connect.NewResponse(syncResponseToProto(response, commandKinds)), nil
}

func (s *Server) WatchFamily(ctx context.Context, req *connect.Request[unetonv1.WatchFamilyRequest], stream *connect.ServerStream[unetonv1.WatchFamilyResponse]) error {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return err
	}
	familyID := req.Msg.GetFamilyId()
	if !s.isMember(ctx, familyID, p.UserID) {
		return connect.NewError(connect.CodePermissionDenied, errors.New("family access required"))
	}
	updates, cancel := s.broker.subscribe(familyID)
	defer cancel()
	latestCursor, err := s.store.Queries.LatestFamilyCursor(ctx, familyID)
	if err != nil {
		return internalError("could not read sync cursor", err)
	}
	if req.Msg.GetGeneration() != s.store.SyncGeneration || latestCursor != req.Msg.GetAfterCursor() {
		return stream.Send(&unetonv1.WatchFamilyResponse{Cursor: latestCursor, Generation: s.store.SyncGeneration, ResetRequired: latestCursor < req.Msg.GetAfterCursor()})
	}
	heartbeat := time.NewTicker(s.streamHeartbeat)
	defer heartbeat.Stop()
	lifetime := s.streamLifetime
	expiresWithToken := p.ExpiresAt.Sub(s.now()) <= lifetime
	if expiresWithToken {
		lifetime = p.ExpiresAt.Sub(s.now())
	}
	expiry := time.NewTimer(lifetime)
	defer expiry.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-expiry.C:
			if expiresWithToken {
				return connect.NewError(connect.CodeUnauthenticated, errors.New("access token expired"))
			}
			return nil
		case <-heartbeat.C:
			cursor, queryErr := s.store.Queries.LatestFamilyCursor(ctx, familyID)
			if queryErr != nil {
				return internalError("could not read sync cursor", queryErr)
			}
			if err := stream.Send(&unetonv1.WatchFamilyResponse{Cursor: cursor, Generation: s.store.SyncGeneration, ResetRequired: cursor < req.Msg.GetAfterCursor()}); err != nil {
				return err
			}
		case cursor := <-updates:
			if cursor > req.Msg.GetAfterCursor() {
				if err := stream.Send(&unetonv1.WatchFamilyResponse{Cursor: cursor, Generation: s.store.SyncGeneration}); err != nil {
					return err
				}
			}
		}
	}
}

func (s *Server) connectPrincipal(ctx context.Context, header http.Header) (principal, error) {
	if p, ok := ctx.Value(principalContextKey{}).(principal); ok {
		return p, nil
	}
	return s.authenticatePrincipal(ctx, header)
}

func syncRequestFromProto(request *unetonv1.SyncRequest) (SyncRequest, map[string]string, error) {
	if request.GetCursor() < 0 {
		return SyncRequest{}, nil, errors.New("cursor cannot be negative")
	}
	result := SyncRequest{Cursor: request.GetCursor(), Generation: request.GetGeneration(), Limit: int(request.GetLimit())}
	kinds := make(map[string]string, len(request.GetCommands()))
	for _, value := range request.GetCommands() {
		if value.GetId() == "" {
			return SyncRequest{}, nil, errors.New("command id is required")
		}
		if _, exists := kinds[value.GetId()]; exists {
			return SyncRequest{}, nil, errors.New("command ids must be unique within a sync request")
		}
		command := Command{ID: value.GetId()}
		if value.ExpectedRevision != nil {
			revision := int(value.GetExpectedRevision())
			command.ExpectedRevision = &revision
		}
		var payload any
		switch item := value.GetPayload().(type) {
		case *unetonv1.Command_CreateChild:
			command.Kind, payload = "createChild", childPayloadFromProto(item.CreateChild.GetChild())
		case *unetonv1.Command_UpdateChild:
			command.Kind, payload = "updateChild", childPayloadFromProto(item.UpdateChild.GetChild())
		case *unetonv1.Command_StartSleep:
			command.Kind, payload = "startSleep", sleepPayloadFromProto(item.StartSleep.GetSleep())
		case *unetonv1.Command_EndSleep:
			command.Kind = "endSleep"
			payload = sleepPayload{ID: item.EndSleep.GetId(), EndedAt: timeFromProto(item.EndSleep.GetEndedAt()), EndCondition: item.EndSleep.GetEndCondition(), WakeMood: item.EndSleep.GetWakeMood(), WakeReason: item.EndSleep.GetWakeReason(), CaregiverIntervened: item.EndSleep.CaregiverIntervened}
		case *unetonv1.Command_UpsertSleep:
			command.Kind, payload = "upsertSleep", sleepPayloadFromProto(item.UpsertSleep.GetSleep())
		case *unetonv1.Command_DeleteSleep:
			command.Kind, payload = "deleteSleep", struct {
				ID string `json:"id"`
			}{ID: item.DeleteSleep.GetId()}
		default:
			return SyncRequest{}, nil, errors.New("command payload is required")
		}
		encoded, err := json.Marshal(payload)
		if err != nil {
			return SyncRequest{}, nil, err
		}
		command.Payload = encoded
		result.Commands = append(result.Commands, command)
		kinds[command.ID] = command.Kind
	}
	return result, kinds, nil
}

func childPayloadFromProto(value *unetonv1.ChildInput) childPayload {
	if value == nil {
		return childPayload{}
	}
	var manual *int
	if value.ManualIntervalMinutes != nil {
		item := int(value.GetManualIntervalMinutes())
		manual = &item
	}
	return childPayload{ID: value.GetId(), Nickname: value.GetNickname(), BirthDate: value.GetBirthDate(), PredictionMode: value.GetPredictionMode(), ManualIntervalMinutes: manual, QuietHoursStartMinutes: int(value.GetQuietHoursStartMinutes()), QuietHoursEndMinutes: int(value.GetQuietHoursEndMinutes()), TimeZone: value.GetTimeZone()}
}

func sleepPayloadFromProto(value *unetonv1.SleepInput) sleepPayload {
	if value == nil {
		return sleepPayload{}
	}
	return sleepPayload{ID: value.GetId(), ChildID: value.GetChildId(), StartedAt: value.GetStartedAt().AsTime(), EndedAt: timeFromProto(value.GetEndedAt()), Source: value.GetSource(), StartCondition: value.GetStartCondition(), SleepLocation: value.GetSleepLocation(), EndCondition: value.GetEndCondition(), WakeMood: value.GetWakeMood(), WakeReason: value.GetWakeReason(), CaregiverIntervened: value.CaregiverIntervened}
}

func timeFromProto(value *timestamppb.Timestamp) *time.Time {
	if value == nil {
		return nil
	}
	parsed := value.AsTime()
	return &parsed
}

func syncResponseToProto(response SyncResponse, commandKinds map[string]string) *unetonv1.SyncResponse {
	result := &unetonv1.SyncResponse{NextCursor: response.NextCursor, HasMore: response.HasMore, ServerTime: timestamppb.New(response.ServerTime), Generation: response.Generation, ResetRequired: response.ResetRequired}
	for _, value := range response.CommandResults {
		status := unetonv1.CommandStatus_COMMAND_STATUS_REJECTED
		if value.Status == "accepted" {
			status = unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED
		}
		result.CommandResults = append(result.CommandResults, &unetonv1.CommandResult{Id: value.ID, Status: status, Error: value.Error, EntityId: value.EntityID, Entity: entityFromJSON(commandEntityType(commandKinds[value.ID]), value.Payload)})
	}
	for _, value := range response.Events {
		result.Events = append(result.Events, &unetonv1.SyncEvent{Cursor: value.Cursor, EntityType: entityTypeToProto(value.EntityType), EntityId: value.EntityID, Operation: operationToProto(value.Operation), Revision: int64(value.Revision), Entity: entityFromJSON(value.EntityType, value.Payload), CreatedAt: timestamppb.New(value.CreatedAt)})
	}
	if response.Snapshot != nil {
		result.Snapshot = &unetonv1.FamilySnapshot{Cursor: response.Snapshot.Cursor, CreatedAt: timestamppb.New(response.Snapshot.CreatedAt)}
		for _, value := range response.Snapshot.Entities {
			result.Snapshot.Entities = append(result.Snapshot.Entities, &unetonv1.SnapshotEntity{EntityType: entityTypeToProto(value.EntityType), EntityId: value.EntityID, Revision: int64(value.Revision), Entity: entityFromJSON(value.EntityType, value.Payload)})
		}
	}
	if response.NextSleepEstimate != nil {
		result.NextSleepEstimate = predictionToProto(response.NextSleepEstimate)
	}
	if response.SleepForecast != nil {
		forecast := response.SleepForecast
		result.SleepForecast = &unetonv1.SleepForecast{ChildId: forecast.ChildID, ActiveSleepId: forecast.ActiveSleepID, WakeEstimate: predictionToProto(forecast.WakeEstimate), NextSleepEstimate: predictionToProto(forecast.NextSleepEstimate), NextSleepIsProvisional: forecast.NextSleepIsProvisional}
	}
	return result
}

func predictionToProto(value *Prediction) *unetonv1.SleepPrediction {
	if value == nil {
		return nil
	}
	return &unetonv1.SleepPrediction{TargetAt: timestamppb.New(value.TargetAt), RangeStartAt: timestamppb.New(value.RangeStartAt), RangeEndAt: timestamppb.New(value.RangeEndAt), Confidence: value.Confidence, Explanation: value.Explanation, AlgorithmVersion: int32(value.AlgorithmVersion), Kind: value.Kind, SampleCount: int32(value.SampleCount)}
}

func commandEntityType(kind string) string {
	if strings.Contains(kind, "Child") || kind == "updatePredictionSettings" {
		return "child"
	}
	return "sleepSession"
}

func entityFromJSON(entityType string, payload []byte) *unetonv1.Entity {
	if len(payload) == 0 {
		return nil
	}
	if entityType == "child" {
		var value childWire
		if json.Unmarshal(payload, &value) != nil {
			return nil
		}
		return &unetonv1.Entity{Value: &unetonv1.Entity_Child{Child: value.proto()}}
	}
	var value sleepRecord
	if json.Unmarshal(payload, &value) == nil && value.ChildID != "" {
		return &unetonv1.Entity{Value: &unetonv1.Entity_SleepSession{SleepSession: sleepRecordToProto(value)}}
	}
	var deleted struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(payload, &deleted) == nil {
		return &unetonv1.Entity{Value: &unetonv1.Entity_Deleted{Deleted: &unetonv1.DeletedEntity{Id: deleted.ID}}}
	}
	return nil
}

type childWire struct {
	ID                     string    `json:"id"`
	FamilyID               string    `json:"familyID"`
	Nickname               string    `json:"nickname"`
	BirthDate              string    `json:"birthDate"`
	PredictionMode         string    `json:"predictionMode"`
	ManualIntervalMinutes  *int      `json:"manualIntervalMinutes"`
	QuietHoursStartMinutes int       `json:"quietHoursStartMinutes"`
	QuietHoursEndMinutes   int       `json:"quietHoursEndMinutes"`
	TimeZone               string    `json:"timeZone"`
	Revision               int       `json:"revision"`
	UpdatedAt              time.Time `json:"updatedAt"`
}

func (value childWire) proto() *unetonv1.Child {
	result := &unetonv1.Child{Id: value.ID, FamilyId: value.FamilyID, Nickname: value.Nickname, BirthDate: value.BirthDate, PredictionMode: value.PredictionMode, QuietHoursStartMinutes: int32(value.QuietHoursStartMinutes), QuietHoursEndMinutes: int32(value.QuietHoursEndMinutes), TimeZone: value.TimeZone, Revision: int64(value.Revision), UpdatedAt: timestamppb.New(value.UpdatedAt)}
	if value.ManualIntervalMinutes != nil {
		item := int32(*value.ManualIntervalMinutes)
		result.ManualIntervalMinutes = &item
	}
	return result
}

func sleepRecordToProto(value sleepRecord) *unetonv1.SleepSession {
	result := &unetonv1.SleepSession{Id: value.ID, FamilyId: value.FamilyID, ChildId: value.ChildID, StartedAt: timestamppb.New(value.StartedAt), Revision: int64(value.Revision), AuthorId: value.AuthorID, Source: value.Source, StartCondition: value.StartCondition, SleepLocation: value.SleepLocation, EndCondition: value.EndCondition, WakeMood: value.WakeMood, WakeReason: value.WakeReason, CaregiverIntervened: value.CaregiverIntervened, UpdatedAt: timestamppb.New(value.UpdatedAt)}
	if value.EndedAt != nil {
		result.EndedAt = timestamppb.New(*value.EndedAt)
	}
	if value.SupersededByID != nil {
		result.SupersededById = value.SupersededByID
	}
	if value.DeletedAt != nil {
		result.DeletedAt = timestamppb.New(*value.DeletedAt)
	}
	return result
}

func entityTypeToProto(value string) unetonv1.EntityType {
	if value == "child" {
		return unetonv1.EntityType_ENTITY_TYPE_CHILD
	}
	return unetonv1.EntityType_ENTITY_TYPE_SLEEP_SESSION
}

func operationToProto(value string) unetonv1.EventOperation {
	if value == "delete" {
		return unetonv1.EventOperation_EVENT_OPERATION_DELETE
	}
	return unetonv1.EventOperation_EVENT_OPERATION_UPSERT
}

func nullString(value string) sql.NullString { return sql.NullString{String: value, Valid: true} }
func invalidArgument(message string) error {
	return connect.NewError(connect.CodeInvalidArgument, errors.New(message))
}

func internalError(message string, cause error) error {
	return connect.NewError(connect.CodeInternal, errors.New(message+": "+cause.Error()))
}
