# Stale voice PR reconciliation (#54)

Date: 2026-08-25

This note records the explicit disposition of PRs #15 and #16 against current `main`. Neither stale branch should be rebased or merged wholesale. Current `main` has materially changed the audio, diagnostics, recovery, RoomSession and TransportAttachment architecture since both PRs were opened.

## PR #15 — voice observability metrics and audit

Decision: **superseded; close without merge**.

| Proposed work | Current-main disposition |
| --- | --- |
| privacy-safe voice-path observability | Superseded by the current `.tarklog` diagnostics, connection-health reporting, transport statistics, link-quality grading and field-test analyzer/runbook work. |
| audio input/output format gauges | Superseded by current negotiated `AudioFormatProfile` diagnostics and audio-engine logging. |
| underrun/overrun/input-stall counters | Superseded by the current playback/media buffer counters, watchdog diagnostics and analyzer-visible health signals. |
| Wi-Fi/Bluetooth disconnect counters | Superseded by typed `ConnectionHealth`, reconnect diagnostics and transport stats. |
| architecture audit document | Historical design input only. The current Room/Transport separation and beta regression plan are the canonical architecture direction. |

No isolated code from #15 remains uniquely valuable enough to port: adding its parallel metrics helper would create a second observability model and duplicate counters already consumed by current diagnostics.

## PR #16 — diagnostics, packet-v2 metadata and connection state machine

Decision: **superseded/parked; close without merge**.

| Proposed work | Current-main disposition |
| --- | --- |
| `VoiceDiagnosticsSnapshot` model | Superseded by current structured diagnostics/log analyzer and per-feature health models. A second snapshot hierarchy would duplicate state. |
| optional audio packet v2 (`0x83`) metadata | **Not retained.** There is no current consumer requiring this wire change. Introducing it now would add mixed-version protocol surface without satisfying a current beta blocker. Revisit only with a concrete latency/stream-identity consumer and golden mixed-version tests. |
| old `ConnectionStateMachine` | Superseded by the current `RoomSession` / `TransportAttachment` boundary, typed connection health, hotspot recovery FSM and selected-network generation/rebind logic. Porting the old machine would create overlapping lifecycle ownership. |
| bounded reconnect/backoff concepts | Retained conceptually and already implemented in current reconnect/recovery paths; no code port required. |
| roadmap issue plan | Historical planning input only; current Epic #34 and issues #36–#54 are canonical. |

## Protocol decision

No packet-v2 code from #16 is merged. The current packet codec remains unchanged. A future protocol extension must have:

1. a concrete runtime consumer,
2. additive/versioned semantics,
3. legacy fallback,
4. malformed-input tests,
5. mixed-version/golden compatibility tests, and
6. evidence that the additional metadata is required for a measured problem.

## Architecture decision

The lifecycle source of truth is the newer Room architecture: logical Room/RoomSession identity and membership survive changes in temporary TransportAttachment state. Concrete transport recovery must integrate through that boundary rather than introduce another cross-transport coordinator/state machine.

## Final disposition

- PR #15: close as superseded by current observability/diagnostics architecture.
- PR #16: close as superseded; explicitly do **not** merge packet-v2 or the old connection state machine.
- No new implementation issue is created from either PR because no unsuperseded code gap was found. If a future measured requirement needs packet metadata, create a fresh focused issue from current `main` rather than reviving #16.
