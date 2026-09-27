# Uneton data inventory and public notices

The authoritative SQLite baseline is `platform/backend/internal/store/migrations/001_initial.sql`. `privacy-data-inventory.json` maps every table to the Apple data categories it can contain. `mise run privacy:check` compares the baseline digest and table set with that inventory, then checks the App Store declaration and `PrivacyInfo.xcprivacy`. A schema edit intentionally stops the check until the inventory and both declarations are reviewed. This is a review gate, not automatic interpretation of a new column's meaning.

The public policy and terms are the HTML templates in `platform/backend/internal/legal/`. The backend fills the operator and contact email from runtime configuration, then serves them at `/privacy`, `/terms`, and `/support` on `api.uneton.app`; the app links to the same pages. The personal values and App Review contact are age-encrypted in `fnox.toml` for local work, while production reads them from its private environment. When the behavior below changes, update the inventory, declarations, public pages, and effective dates together. App Store Connect changes are applied only through the local store commands after a remote plan.

| Data | Source and purpose | Retention and deletion |
| --- | --- | --- |
| Apple subject, provided display name, encrypted refresh credential | `users`; sign-in, account recovery, credential audit and revocation | Kept while the account is active. Account erasure clears private identity and credential material and leaves a referential tombstone. |
| Family membership and invitations | `families`, `family_members`, `invites`; share the diary with chosen caregivers | Membership ends on removal or account deletion. A family survives when another caregiver inherits ownership; otherwise it is deleted. Invitation links expire after seven days, but expired database rows are not currently pruned. |
| Child settings, sleep history and growth observations | `children`, `sleep_sessions`, `growth_measurements`; diary, reminders, forecasts and growth charts | Kept with the shared family. An item deleted in the app has a tombstone for sync; physical removal is not guaranteed until its family is deleted. This is health-related child data. |
| Device and notification identifiers | `devices`, `live_activity_tokens`, `live_activity_starts`; authentication, APNs and Live Activities | Device sign-out or account deletion removes the device row and associated push tokens. Invalid tokens may be cleared earlier. |
| Commands, events, snapshots and delivery payloads | `commands`, `sync_events`, `family_sync_snapshots`, `deliveries`; idempotent sync, restore recovery and push delivery | Command results and snapshots may remain for the family's lifetime. Events compact behind a snapshot. Sent deliveries are pruned after seven days; pending delivery may remain until resolved. |
| Operational diagnostics | Backend panic/error logs and container runtime; reliability and security | The code does not intentionally log request bodies or credentials. The repository does not currently enforce a log retention period. Operators must configure host journal retention before production and review any new telemetry fields. |
| Backup replica | Litestream's copy of the authoritative SQLite database | The configured replica rotates snapshots and WAL on a 24-hour retention period. A deleted record may persist until that rotation. Restore requires reapplying post-snapshot deletion and rotating the sync generation. |
| Device-local records | SQLite projection, pending and acknowledged commands, Keychain credentials, UserDefaults device and reminder preferences | These support offline work and authentication. Sign-out clears account-scoped local state only after pending changes have synchronized; uninstall removes the app's local copy. These are not a separate server-held dataset. |
| Static growth reference points | `growth_reference_points`; non-family chart reference | The reference is not personal information and is excluded from the App Store collection declaration. |

## External recipients and choices

An invited caregiver can access the family's diary. Apple handles Sign in with Apple and APNs delivery. The production server and its backup host the service data; the repository does not establish a third-party analytics, advertising, email or AI processing integration. The app does not use HealthKit or upload address-book contacts. `CONTACTS` in the declaration describes the in-app caregiver relationship, not a device-address-book permission.

Notification and Live Activity switches are device-scoped. The app offers account deletion, with the ownership-transfer rule above. There is no self-service account-data export yet; access requests go to the privacy contact in the public policy. The policy should not claim an export feature until one exists. The age-rating declaration marks health/wellness topics and user-generated content because caregivers enter and share diary records inside a family; it does not claim public social media or medical treatment information.

## Change checklist

Before adding a user-linked field, new processor, analytics event, retention rule, or new app capability:

1. Record what is collected, why, where it is stored, and whether a caregiver can see another caregiver's entry.
2. Decide how it is removed on item deletion, sign-out, family deletion and account erasure, including backups and pending offline commands.
3. Update `privacy-data-inventory.json`, the App Store declaration, the app privacy manifest, public notices and age-rating answers when affected.
4. Run `mise run privacy:check`, `mise run store -- validate`, and the relevant backend or Apple tests.
5. Plan remote App Store Connect drift before applying or publishing questionnaire changes.
