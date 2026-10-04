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

`View.palette(_:)` installs a palette for a subtree: the environment value, the native control tint, and the matching light or dark appearance. `TimelineScreen` resolves the mode from the active sleep, system appearance and the night light toggle. `SkyBackground` (via `View.skyBackground()`) draws the animated sky from the palette behind every tab and full screen, including loading states; sheets keep their system Liquid Glass; `GlassCard`, `StatTile`, `TabHeader` and `DiaryRow` are the shared building blocks. Inputs, toolbars, sheets and tab bars stay native (`glassProminent`, segmented pickers, forms) and pick up the tint.

## Time of day

`Palette.sky(at: DayPhase)` gives the sky for the current local time. Each palette stores four anchor skies (noon, midnight, dawn, dusk) and blends them in linear light, so a blended sky's luminance always lies between the anchors'. Text roles are solved against every anchor, which keeps them readable at any hour; `PaletteTests` sweeps the day in 15 minute steps. Day anchors keep noon's lightness and only move hue and chroma (peach dawn, rose dusk). Night anchors only darken toward midnight and add stars. Night light has no time of day. `DayPhase` uses the clock (dawn peaks 06:30, dusk 19:00), not the real sun, because the app has no location.

In the app the sun and moon move along an arc in the top trailing corner, clear of the leading screen titles. The night palette always shows the moon. Clouds and star twinkles complete whole cycles per hour, so the shader loops at 3600 seconds without a jump. Every `SkyBackground` derives motion from the wall clock, so tabs and screens show the same frame. Palette mode changes crossfade over 1.2 seconds. Reduce Motion and night light hold the clouds still but still refresh the colors each minute.

## Live Activity and Watch

The Live Activity (`SleepActivityPalette` in UnetonActivity) uses the day palette for its light lock screen card and the night palette for the Dynamic Island. The Watch is always dark and uses the night palette. Both use the same seed as the app.

## Per-child colors later

A child color setting only needs to store a seed and pass it to `Palette.make(seed:mode:)` where `TimelineScreen` builds its palette. Storing it is user data on the child record, so it is a synchronized mutation and must follow the complete command path in `AGENTS.md`.
