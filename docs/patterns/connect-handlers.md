# Connect handler policy

The protobuf service is the source of callable operations. Generated Connect handlers provide transport mechanics; `internal/transport/connectapi.Procedures` provides the human-auditable policy vocabulary.

Every procedure declares:

- exact generated procedure path;
- public, authenticated, or development-only access;
- unary or server-stream behavior.

The policy interceptor authenticates once and places the verified user/device principal in the request context. Handlers still enforce family membership and owner roles because those are domain authorization decisions. A contract test compares the inventory with protobuf reflection, so adding an RPC without declaring policy fails tests.

Do not add handwritten JSON alternatives for RPC behavior. Apple server notifications are the deliberate exception because Apple defines that form-encoded HTTP callback.
