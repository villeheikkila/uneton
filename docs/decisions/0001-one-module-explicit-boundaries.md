# ADR 0001: One Go module with explicit repository boundaries

Status: accepted

Uneton keeps one root Go module while separating contracts, backend, infrastructure, clients, and local tooling into owned directories. This keeps navigation and dependency direction clear without introducing multi-module release/version overhead before the service needs it.

Generated Go bindings stay in root `internal/gen` so the backend and load client share the exact contract. Generated Swift bindings are committed under `clients/ios/UnetonPackage` so normal Apple builds do not require Buf plugins.
