package connectapi

import (
	"context"
	"errors"
	"net/http"

	"connectrpc.com/connect"
)

type Authenticate func(context.Context, http.Header) (context.Context, error)

type policyInterceptor struct {
	authenticate Authenticate
	development  bool
}

func NewPolicyInterceptor(authenticate Authenticate, development bool) connect.Interceptor {
	return &policyInterceptor{authenticate: authenticate, development: development}
}

func (i *policyInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, request connect.AnyRequest) (connect.AnyResponse, error) {
		ctx, err := i.authorize(ctx, request.Spec().Procedure, request.Header())
		if err != nil {
			return nil, err
		}
		return next(ctx, request)
	}
}

func (i *policyInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (i *policyInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, connection connect.StreamingHandlerConn) error {
		ctx, err := i.authorize(ctx, connection.Spec().Procedure, connection.RequestHeader())
		if err != nil {
			return err
		}
		return next(ctx, connection)
	}
}

func (i *policyInterceptor) authorize(ctx context.Context, path string, header http.Header) (context.Context, error) {
	procedure, err := Lookup(path)
	if err != nil {
		return ctx, connect.NewError(connect.CodeInternal, err)
	}
	switch procedure.Access {
	case Public:
		return ctx, nil
	case DevelopmentOnly:
		if !i.development {
			return ctx, connect.NewError(connect.CodeUnimplemented, errors.New("development sign-in is disabled"))
		}
		return ctx, nil
	case Authenticated:
		return i.authenticate(ctx, header)
	default:
		return ctx, connect.NewError(connect.CodeInternal, errors.New("invalid procedure access policy"))
	}
}
