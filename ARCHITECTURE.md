# Architecture

Tark follows clean architecture with isolated features that communicate
only through per-feature API layers.

## Layout

```
lib/
  app/          Composition root — the ONLY place features are wired together.
    di/         injectable/get_it config (generated di_config.config.dart may
                import feature internals; that is expected).
    router/     GoRouter table mapping AppRoutes constants to feature pages.
  core/         Shared kernel: theme, l10n, error types, utils, shared widgets,
                route-name constants. Core NEVER imports from lib/feature or
                lib/app.
  feature/<name>/
    api/        The feature's public surface: a barrel exporting the contracts,
                entities, and widgets other code may use.
    domain/     Entities, service/repository interfaces, pure logic (DSP etc.).
                No platform or package I/O.
    data/       Implementations of domain interfaces; owns plugins, sockets,
                codecs, persistence.
    presentation/  Pages, widgets, cubits.
```

## Rules

1. **Cross-feature imports go through `feature/<x>/api/` only.** Never import
   another feature's `domain/`, `data/`, or `presentation/` files directly.
2. **Inside a feature**: presentation → domain, data → domain. Domain imports
   nothing from data or presentation.
3. **Core is import-only**: features and app may import core; core imports
   neither.
4. **Navigation by name**: features call `context.pushNamed(AppRoutes.xName)`
   (constants in `core/router/routes.dart`). Only `app/router/app_router.dart`
   imports page widgets across features.
5. **The app layer** (`lib/app/`, `lib/main.dart`) is the composition root and
   may import feature APIs; the DI config additionally wires data-layer
   implementations to domain interfaces.

## Feature APIs

- **audio** — `AudioEngine` (duplex mic/speaker contract), `AudioFrame`,
  `AudioEngineStatus`, `AudioVisualizer` widget, wire-format constants.
  The implementation (`AudioEngineImpl`) owns the `audio_io` plugin and the
  static epoch/lock guards that keep engine stop/start transitions safe across
  overlapping page sessions — see the comments in
  `feature/audio/data/audio_engine_impl.dart` before touching lifecycle code.
- **transfer** — owns the wire protocol (`WakiPacket`) and its transports:
  `TransferRepository` (WiFi UDP / Bluetooth impls selected per
  `TransferModeStore.mode` by a DI factory), `TransferMode`,
  `TransferModeStore`, and the Bluetooth connect page.
- **walkie** — the channel screen; consumes audio + transfer through their
  APIs. Exposes only its page (reached via routes).
- **landing** — entry screen; consumes transfer's API for mode selection.

## DI

Registrations are annotation-driven (`injectable`). After changing any
`@injectable`/`@module` annotation, regenerate with:

```
flutter pub run build_runner build
```
