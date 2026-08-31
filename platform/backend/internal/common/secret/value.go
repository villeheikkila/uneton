package secret

import "fmt"

// Value prevents configuration secrets from being exposed by ordinary logging.
type Value struct{ value string }

func New(value string) Value { return Value{value: value} }

func (v Value) Reveal() string { return v.value }

func (Value) String() string { return "***" }

func (Value) LogValue() any { return "***" }

func (Value) GoString() string { return "secret.Value(***)" }

func (v Value) Empty() bool { return v.value == "" }

func (v Value) Format(state fmt.State, _ rune) { _, _ = state.Write([]byte("***")) }
