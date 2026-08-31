// Package connectapi owns transport policy for the generated Connect service.
// Business behavior remains in app; this package is the auditable inventory of
// every network procedure and its cross-cutting policy.
package connectapi

import (
	"fmt"

	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
)

type Access uint8

const (
	Public Access = iota
	Authenticated
	DevelopmentOnly
)

type Kind uint8

const (
	Unary Kind = iota
	ServerStream
)

type Procedure struct {
	Path   string
	Access Access
	Kind   Kind
}

var Procedures = [...]Procedure{
	{Path: unetonv1connect.UnetonServiceDevelopmentAuthProcedure, Access: DevelopmentOnly, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceAppleAuthProcedure, Access: Public, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceRefreshAuthProcedure, Access: Public, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceSignOutProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceDeleteAccountProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceUpdateDevicePushSettingsProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceRegisterLiveActivityProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceCreateFamilyProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceCreateInviteProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceAcceptInviteProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceSyncProcedure, Access: Authenticated, Kind: Unary},
	{Path: unetonv1connect.UnetonServiceWatchFamilyProcedure, Access: Authenticated, Kind: ServerStream},
}

func Lookup(path string) (Procedure, error) {
	for _, procedure := range Procedures {
		if procedure.Path == path {
			return procedure, nil
		}
	}
	return Procedure{}, fmt.Errorf("connect procedure %q has no declared policy", path)
}
