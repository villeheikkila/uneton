package connectapi

import (
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
)

func TestEveryProtoMethodHasExactlyOnePolicy(t *testing.T) {
	methods := unetonv1.File_uneton_v1_uneton_proto.Services().ByName("UnetonService").Methods()
	if methods.Len() != len(Procedures) {
		t.Fatalf("protobuf has %d methods but policy inventory has %d", methods.Len(), len(Procedures))
	}
	seen := make(map[string]struct{}, len(Procedures))
	for _, procedure := range Procedures {
		if _, exists := seen[procedure.Path]; exists {
			t.Errorf("duplicate policy for %s", procedure.Path)
		}
		seen[procedure.Path] = struct{}{}
		method := methods.ByName(methodName(procedure.Path))
		if method == nil {
			t.Errorf("policy references unknown procedure %s", procedure.Path)
			continue
		}
		wantKind := Unary
		if method.IsStreamingServer() {
			wantKind = ServerStream
		}
		if procedure.Kind != wantKind {
			t.Errorf("%s has kind %d, want %d", procedure.Path, procedure.Kind, wantKind)
		}
	}
}

func methodName(path string) protoreflect.Name {
	for index := len(path) - 1; index >= 0; index-- {
		if path[index] == '/' {
			return protoreflect.Name(path[index+1:])
		}
	}
	return ""
}
