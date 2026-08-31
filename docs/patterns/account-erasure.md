# Account erasure

Account erasure is one SQLite transaction:

1. For every owned family, select the oldest active caregiver deterministically by join time and user ID.
2. Transfer `families.owner_id` and promote that membership to `owner`.
3. If no caregiver exists, delete the family and let foreign-key cascades remove its diary.
4. Remove the departing user's remaining memberships and every device session.
5. Replace the Apple subject with a unique tombstone, clear profile/provider credentials, and set `deleted_at`.

The user row remains as a referential tombstone; private identity and authentication material do not. Retrying a provider notification after completion is a successful no-op. Never put Apple network calls inside this transaction.
