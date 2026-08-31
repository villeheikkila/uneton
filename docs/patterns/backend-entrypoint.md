# Backend entry point

`cmd/server/main.go` must stay testable and nearly free of policy. `run` parses the command (`serve`, `config`, or `database-check`), loads the strict `UNETON_*` environment snapshot, and returns an error instead of exiting deep in the call graph.

Configuration rejects unknown project-prefixed variables. Secret values use the redacting wrapper and must never appear in config output or structured logs. Production enables Sign in with Apple and its HTTPS server-notification URL; provider endpoint overrides are development-only.

The application runner binds the listener synchronously so startup failures are reported before serving, marks readiness false before shutdown, and gives active requests the configured graceful-shutdown window.
