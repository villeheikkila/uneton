# Apple client colors

All app colors come from one palette, built from one seed color, in `clients/ios/UnetonPackage/Sources/UnetonTheme`. Views never hard-code colors; they read semantic roles from the `\.palette` environment value.

## Seed, mode, roles

- **Seed** (`PaletteSeed`): a hue and a soft chroma. Every child currently uses `.sky`. Presets exist for blossom, lavender, meadow and honey, and `PaletteSeed(hex:)` turns any picked color into a calm seed by capping its chroma.
- **Mode** (`PaletteMode`): `day`, `night` (a night sleep is running, or the device prefers dark appearance) or `nightLight` (opt-in, very dim amber during a night sleep). `SleepAppearance.mode` makes that decision; whether a sleep counts as night is `SleepKind` in UnetonCore.
- **Roles** (`Palette`): sky gradient, clouds, celestial (sun or moon), `ink`, `inkSecondary`, `accent` with `onAccent`, `accentSoft`, `track`, `surface`, and `wake` with `onWake`.

## Color math

Palettes are computed in OKLCH, so equal lightness steps look equal and changing the hue keeps contrast stable. Each text role starts from a target lightness and is walked darker or lighter until it meets its contrast ratio against every background it sits on: 7:1 for `ink`, 4.5:1 for `inkSecondary`, `onAccent` and `onWake`. Out-of-gamut colors keep their lightness and hue and lose chroma. `PaletteTests` sweeps the hue circle at several chroma levels in every mode, so a new seed cannot ship unreadable text.

Two roles ignore the seed on purpose: `wake` is always warm so "woke up" reads as morning, and night light is always amber because its job is low blue light.

## Using it in the app

`View.palette(_:)` installs a palette for a subtree: the environment value, the native control tint, and the matching light or dark appearance. `TimelineScreen` resolves the mode from the active sleep, system appearance and the night light toggle. `SkyBackground` draws the animated sky from the palette; `GlassCard`, `StatTile`, `TabHeader` and `DiaryRow` are the shared building blocks. Inputs, toolbars, sheets and tab bars stay native (`glassProminent`, segmented pickers, forms) and pick up the tint.

## Live Activity and Watch

The Live Activity (`SleepActivityPalette` in UnetonActivity) uses the day palette for its light lock screen card and the night palette for the Dynamic Island. The Watch is always dark and uses the night palette. Both use the same seed as the app.

## Per-child colors later

A child color setting only needs to store a seed and pass it to `Palette.make(seed:mode:)` where `TimelineScreen` builds its palette. Storing it is user data on the child record, so it is a synchronized mutation and must follow the complete command path in `AGENTS.md`.
