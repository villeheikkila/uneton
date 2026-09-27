# Uneton App Store Connect state

This directory holds the Git-owned listing and questionnaire answers for the single Uneton iOS app (`solutions.bytesized.uneton`). It follows the local Maku pattern: validate the files, plan against Apple, review the diff, apply explicitly, and check for drift. It does not run in remote CI/CD.

- `metadata/` has the initial English app-info and version listing. The first version omits `whatsNew`, which Apple does not accept on an initial release.
- `privacy.json` is inferred from `docs/privacy-data-inventory.json` and checked against `Uneton/PrivacyInfo.xcprivacy` by `mise run privacy:check`.
- `age-rating.json` records the full age-rating answers. Health/wellness topics and caregiver-shared user content are enabled.
- `readiness.json` records a proposed initial category, content-rights answer, free price, Finland availability, App Review contact, and pending reviewer access requirement. Review the territory and content-rights choices before applying them in App Store Connect.
- `testflight/en-US.txt` and `testflight/fi.txt` are the canonical What to Test notes for local distribution.

The public privacy policy, terms and support pages are served by the backend at `https://api.uneton.app/privacy`, `/terms`, and `/support`. They must be reachable before applying the listing URLs in App Store Connect. The pages contain templates. Production requires `UNETON_LEGAL_OPERATOR_NAME` and `UNETON_LEGAL_CONTACT_EMAIL` in the VPS secret environment; locally, `mise run dev:legal` injects the age-encrypted values from `fnox.toml`. The rendered public pages necessarily reveal the contact email to visitors.

## Local setup

The App Store Connect app record did not exist for the production bundle ID when this tree was prepared. Create it in App Store Connect, then set `ASC_APP_ID` to its numeric ID. Authenticate `asc` locally with an API key, and use an authenticated Apple web session for `asc web privacy` commands. Xcode also needs distribution signing for the app, Watch and widget targets. The App Review contact and legal operator values are age-encrypted in `fnox.toml`, using the key at `~/.config/sops/age/keys.txt`. Keep the key, demo credentials, and production `.env` out of Git.

```sh
export ASC_APP_ID=1234567890 # replace with the actual numeric app ID
mise run store -- validate
mise run store -- plan
mise run store -- approve
mise run store -- apply
mise run store -- publish-privacy
mise run store -- drift
mise run store -- submission-check
```

`plan` reads Apple state, shows the proposed readiness settings, and writes a local metadata review artifact under ignored `.asc/metadata/`. `approve` only changes that local artifact. `apply` requires a clean checkout, applies approved metadata and the privacy and age-rating answers, and does not publish the privacy questionnaire. `publish-privacy` is separate because it changes the public product page. `drift` is read-only and exits with status 3 if managed metadata, privacy, or age-rating state differs. `submission-check` runs Apple's readiness and review diagnostics without submitting.

After reviewer access is implemented, set `reviewAccess.status` to `READY`, choose `DEMO_MODE` or `DEMO_ACCOUNT`, and replace the pending notes with real reviewer instructions. `mise run store -- readiness-apply` then decrypts the contact values locally and applies the category, content rights, copyright, free pricing, availability and review details. For `DEMO_ACCOUNT`, supply `ASC_REVIEW_DEMO_NAME` and `ASC_REVIEW_DEMO_PASSWORD` in the local environment; never commit them. This command is intentionally blocked while reviewer access is pending.

The version defaults to `1.0`; set `UNETON_STORE_VERSION` when preparing a later version and add its localized files first. The `store` command verifies that `ASC_APP_ID` resolves to `solutions.bytesized.uneton` before any remote mutation.

## Builds, TestFlight and review

Build locally with `mise run release:ios:build -- VERSION BUILD_NUMBER`. Upload and attach the resulting IPA with `mise run release:ios:upload -- IPA_PATH --publish`. These steps do not submit for review. Resolve the processed build ID with `asc builds info --app "$ASC_APP_ID" --build-number BUILD_NUMBER --version VERSION --platform IOS`.

Create an internal or external TestFlight group with `asc testflight groups create --app "$ASC_APP_ID" --name "Uneton Beta"` and manage testers with `asc testflight testers`. Then preview and distribute the processed build:

```sh
mise run release:ios:testflight -- BUILD_ID GROUP_ID
mise run release:ios:testflight -- BUILD_ID GROUP_ID --publish
```

The command uses the checked-in English What to Test note. Set `UNETON_TESTFLIGHT_LOCALE=fi` to use the Finnish note. External groups can require TestFlight beta review; inspect `asc testflight review` and submit that separately when necessary. Review feedback and crashes are available under `asc testflight feedback` and `asc testflight crashes`.

Before App Review submission, supply screenshots and any required export-compliance answers. Apple also requires an active demo account or a fully featured demo mode for account-based features; the current Sign in with Apple-only app has no dedicated reviewer access path, so `readiness.json` keeps this marked pending and the local command blocks `--submit`. The local review command checks declaration drift and Apple's readiness diagnostics before previewing a submission. After resolving any blockers, use `--submit` to send it to Apple:

```sh
mise run release:ios:review -- BUILD_ID
mise run release:ios:review -- BUILD_ID --submit
asc review status --app "$ASC_APP_ID"
```

The legal contact, review contact details, territory choices, and screenshots need owner review before the initial live listing. No task here creates an app record, sends TestFlight invitations, submits for review, or changes App Store Connect as a side effect of a local validation command.
