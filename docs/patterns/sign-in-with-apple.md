# Sign in with Apple

The client creates a random nonce, sends its SHA-256 hash to Apple, and sends the raw nonce plus authorization code to Uneton. The backend exchanges the one-time code itself and validates only the returned identity token: RS256, Apple issuer, Uneton audience, expiry, subject, and constant-time nonce comparison. A client-supplied identity token is not part of the contract.

Apple refresh tokens are server credentials. Their ciphertext envelope records a key ID; production supplies a JSON keyring and an active key ID. Startup rewraps old ciphertext with the active key, so operators add a new key, deploy and verify rewrap, and only then remove the old key. Revocation is attempted during user-requested deletion, but provider downtime never blocks local erasure.

The configured server-notification URL accepts only bounded `application/x-www-form-urlencoded` requests. It verifies Apple's JWS before reading the event. `consent-revoked` and `account-deleted` immediately run the same idempotent account-erasure transaction as the authenticated delete RPC. Unknown subjects return success because Apple may redeliver events.

The backend also audits stored refresh tokens every 24 hours. Network errors and provider 5xx responses only produce an inconclusive audit; a definitive Apple `invalid_grant` immediately invokes account erasure. A rotated refresh token is encrypted with the active key before replacing the old value.

On iOS, credential-state checks are throttled to once per 24 hours and also run immediately after `credentialRevokedNotification`. `.authorized` and `.transferred` are valid; `.revoked` and `.notFound` clear the local session. Offline/provider failures do not destroy a usable server session.
