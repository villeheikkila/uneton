package app

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func (s *Server) GetFamilyManagement(ctx context.Context, req *connect.Request[unetonv1.GetFamilyManagementRequest]) (*connect.Response[unetonv1.GetFamilyManagementResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	familyID := req.Msg.GetFamilyId()
	if !s.isMember(ctx, familyID, p.UserID) {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("family access required"))
	}
	family, err := s.store.Queries.FamilyByID(ctx, familyID)
	if err != nil {
		return nil, internalError("could not read family", err)
	}
	role, err := s.store.Queries.FamilyMemberRole(ctx, storedb.FamilyMemberRoleParams{FamilyID: familyID, UserID: p.UserID})
	if err != nil {
		return nil, internalError("could not read role", err)
	}
	name, err := s.store.Queries.UserDisplayName(ctx, p.UserID)
	if err != nil {
		return nil, internalError("could not read profile", err)
	}
	rows, err := s.store.Queries.ActiveFamilyMembers(ctx, familyID)
	if err != nil {
		return nil, internalError("could not read family members", err)
	}
	result := &unetonv1.GetFamilyManagementResponse{FamilyId: familyID, FamilyName: family.Name, MyUserId: p.UserID, MyDisplayName: name, MyRole: role}
	for _, row := range rows {
		joined, parseErr := parseTime(row.JoinedAt)
		if parseErr != nil {
			return nil, internalError("invalid member date", parseErr)
		}
		result.Members = append(result.Members, &unetonv1.FamilyMemberInfo{UserId: row.UserID, DisplayName: row.DisplayName, Role: row.Role, JoinedAt: timestamppb.New(joined)})
	}
	if role == "owner" {
		invites, readErr := s.store.Queries.PendingFamilyInvites(ctx, storedb.PendingFamilyInvitesParams{FamilyID: familyID, Now: formatTime(s.now().UTC())})
		if readErr != nil {
			return nil, internalError("could not read invitations", readErr)
		}
		for _, invite := range invites {
			expires, expiryErr := parseTime(invite.ExpiresAt)
			created, createdErr := parseTime(invite.CreatedAt)
			if expiryErr != nil || createdErr != nil {
				return nil, internalError("invalid invitation date", errors.Join(expiryErr, createdErr))
			}
			result.PendingInvites = append(result.PendingInvites, &unetonv1.FamilyInviteInfo{Id: invite.ID, ExpiresAt: timestamppb.New(expires), CreatedAt: timestamppb.New(created)})
		}
	}
	return connect.NewResponse(result), nil
}

func (s *Server) UpdateProfile(ctx context.Context, req *connect.Request[unetonv1.UpdateProfileRequest]) (*connect.Response[unetonv1.UpdateProfileResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	name := strings.TrimSpace(req.Msg.GetDisplayName())
	if name == "" || len([]rune(name)) > 80 {
		return nil, invalidArgument("display name must be 1–80 characters")
	}
	rows, err := s.store.Queries.UpdateUserDisplayName(ctx, storedb.UpdateUserDisplayNameParams{DisplayName: name, ID: p.UserID})
	if err != nil {
		return nil, internalError("could not update profile", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("profile not found"))
	}
	return connect.NewResponse(&unetonv1.UpdateProfileResponse{DisplayName: name}), nil
}

func (s *Server) RenameFamily(ctx context.Context, req *connect.Request[unetonv1.RenameFamilyRequest]) (*connect.Response[unetonv1.RenameFamilyResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	name := strings.TrimSpace(req.Msg.GetName())
	if name == "" || len([]rune(name)) > 80 {
		return nil, invalidArgument("family name must be 1–80 characters")
	}
	if !s.hasRole(ctx, req.Msg.GetFamilyId(), p.UserID, "owner") {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("owner access required"))
	}
	rows, err := s.store.Queries.RenameFamily(ctx, storedb.RenameFamilyParams{Name: name, ID: req.Msg.GetFamilyId(), OwnerID: p.UserID})
	if err != nil {
		return nil, internalError("could not rename family", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("family not found"))
	}
	return connect.NewResponse(&unetonv1.RenameFamilyResponse{Name: name}), nil
}

func (s *Server) RemoveFamilyMember(ctx context.Context, req *connect.Request[unetonv1.RemoveFamilyMemberRequest]) (*connect.Response[unetonv1.RemoveFamilyMemberResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	if !s.hasRole(ctx, req.Msg.GetFamilyId(), p.UserID, "owner") {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("owner access required"))
	}
	if req.Msg.GetUserId() == p.UserID {
		return nil, invalidArgument("use leave family for your own membership")
	}
	rows, err := s.store.Queries.RemoveCaregiver(ctx, storedb.RemoveCaregiverParams{RemovedAt: sql.NullString{String: formatTime(s.now().UTC()), Valid: true}, FamilyID: req.Msg.GetFamilyId(), UserID: req.Msg.GetUserId(), ActorID: p.UserID})
	if err != nil {
		return nil, internalError("could not remove caregiver", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("active caregiver not found"))
	}
	return connect.NewResponse(&unetonv1.RemoveFamilyMemberResponse{}), nil
}

func (s *Server) LeaveFamily(ctx context.Context, req *connect.Request[unetonv1.LeaveFamilyRequest]) (*connect.Response[unetonv1.LeaveFamilyResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	role, err := s.store.Queries.FamilyMemberRole(ctx, storedb.FamilyMemberRoleParams{FamilyID: req.Msg.GetFamilyId(), UserID: p.UserID})
	if errors.Is(err, sql.ErrNoRows) {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("family membership not found"))
	}
	if err != nil {
		return nil, internalError("could not read membership", err)
	}
	if role == "owner" {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("transfer ownership or delete the family first"))
	}
	rows, err := s.store.Queries.RemoveCaregiver(ctx, storedb.RemoveCaregiverParams{RemovedAt: sql.NullString{String: formatTime(s.now().UTC()), Valid: true}, FamilyID: req.Msg.GetFamilyId(), UserID: p.UserID, ActorID: p.UserID})
	if err != nil {
		return nil, internalError("could not leave family", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("family membership not found"))
	}
	return connect.NewResponse(&unetonv1.LeaveFamilyResponse{}), nil
}

func (s *Server) TransferFamilyOwnership(ctx context.Context, req *connect.Request[unetonv1.TransferFamilyOwnershipRequest]) (*connect.Response[unetonv1.TransferFamilyOwnershipResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	familyID, successorID := req.Msg.GetFamilyId(), req.Msg.GetUserId()
	if successorID == "" || successorID == p.UserID {
		return nil, invalidArgument("choose another caregiver")
	}
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, internalError("database unavailable", err)
	}
	defer func() { _ = tx.Rollback() }()
	q := s.store.Queries.WithTx(tx)
	role, err := q.FamilyMemberRole(ctx, storedb.FamilyMemberRoleParams{FamilyID: familyID, UserID: successorID})
	if err != nil || role != "caregiver" {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("successor must be an active caregiver"))
	}
	rows, err := q.TransferFamilyOwnership(ctx, storedb.TransferFamilyOwnershipParams{SuccessorID: successorID, ID: familyID, OwnerID: p.UserID})
	if err != nil {
		return nil, internalError("could not transfer ownership", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("owner access required"))
	}
	rows, err = q.DemoteFamilyOwner(ctx, storedb.DemoteFamilyOwnerParams{FamilyID: familyID, UserID: p.UserID})
	if err != nil || rows != 1 {
		return nil, internalError("could not transfer ownership", err)
	}
	rows, err = q.PromoteFamilyOwner(ctx, storedb.PromoteFamilyOwnerParams{FamilyID: familyID, UserID: successorID})
	if err != nil || rows != 1 {
		return nil, internalError("could not transfer ownership", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, internalError("could not transfer ownership", err)
	}
	return connect.NewResponse(&unetonv1.TransferFamilyOwnershipResponse{}), nil
}

func (s *Server) RevokeInvite(ctx context.Context, req *connect.Request[unetonv1.RevokeInviteRequest]) (*connect.Response[unetonv1.RevokeInviteResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	if !s.hasRole(ctx, req.Msg.GetFamilyId(), p.UserID, "owner") {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("owner access required"))
	}
	rows, err := s.store.Queries.RevokePendingInvite(ctx, storedb.RevokePendingInviteParams{ID: req.Msg.GetInviteId(), FamilyID: req.Msg.GetFamilyId(), OwnerID: p.UserID})
	if err != nil {
		return nil, internalError("could not revoke invitation", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("pending invitation not found"))
	}
	return connect.NewResponse(&unetonv1.RevokeInviteResponse{}), nil
}

func (s *Server) DeleteFamily(ctx context.Context, req *connect.Request[unetonv1.DeleteFamilyRequest]) (*connect.Response[unetonv1.DeleteFamilyResponse], error) {
	p, err := s.connectPrincipal(ctx, req.Header())
	if err != nil {
		return nil, err
	}
	if !s.hasRole(ctx, req.Msg.GetFamilyId(), p.UserID, "owner") {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("owner access required"))
	}
	count, err := s.store.Queries.ActiveFamilyMemberCount(ctx, req.Msg.GetFamilyId())
	if err != nil {
		return nil, internalError("could not count caregivers", err)
	}
	if count != 1 {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("remove other caregivers before deleting the family"))
	}
	rows, err := s.store.Queries.DeleteSoleOwnerFamily(ctx, storedb.DeleteSoleOwnerFamilyParams{ID: req.Msg.GetFamilyId(), OwnerID: p.UserID})
	if err != nil {
		return nil, internalError("could not delete family", err)
	}
	if rows != 1 {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("family not found"))
	}
	return connect.NewResponse(&unetonv1.DeleteFamilyResponse{}), nil
}
