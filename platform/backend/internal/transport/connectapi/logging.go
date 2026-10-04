package connectapi

import (
	"context"
	"errors"
	"log/slog"

	"connectrpc.com/connect"
)

// NewErrorLogInterceptor logs every failed RPC with its procedure and Connect
// code. Without it, a client-visible failure such as a rejected sign-in leaves
// no trace on the server. Messages never include request bodies or tokens.
func NewErrorLogInterceptor(logger *slog.Logger) connect.Interceptor {
	return &errorLogInterceptor{logger: logger}
}

type errorLogInterceptor struct {
	logger *slog.Logger
}

func (i *errorLogInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, request connect.AnyRequest) (connect.AnyResponse, error) {
		response, err := next(ctx, request)
		i.log(ctx, request.Spec().Procedure, err)
		return response, err
	}
}

func (i *errorLogInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (i *errorLogInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, connection connect.StreamingHandlerConn) error {
		err := next(ctx, connection)
		i.log(ctx, connection.Spec().Procedure, err)
		return err
	}
}

func (i *errorLogInterceptor) log(ctx context.Context, procedure string, err error) {
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	code := connect.CodeOf(err)
	level := slog.LevelWarn
	if code == connect.CodeInternal || code == connect.CodeUnknown {
		level = slog.LevelError
	}
	i.logger.Log(ctx, level, "rpc failed", "procedure", procedure, "code", code.String(), "error", err.Error())
}
