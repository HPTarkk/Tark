# Voice Phase 2 issue plan

These local issue drafts were created because this checkout has no configured GitHub remote or issue tracker credentials. They should be copied into the repository tracker without creating duplicates.

Each item uses labels where equivalent labels exist: voice, audio, networking, bluetooth, wifi, webrtc, reliability, performance, observability, architecture, android, ios.

## 1. Voice diagnostics and latency instrumentation
- Problem: Voice reliability cannot be compared across transports because there is no shared diagnostics snapshot.
- Evidence from repository: voice packets, Wi-Fi, Bluetooth, WebRTC, and playback buffering live in separate feature files with no common telemetry model.
- Proposed solution: Add a privacy-safe diagnostics model and debug-only viewer/export path.
- Scope: audio/network/session counters and latency fields.
- Out of scope: audio content capture, tokens, full SDP, and public IP logging.
- Acceptance criteria: debug builds can inspect a snapshot; release logs redact addresses and omit high-volume payloads.
- Testing plan: unit tests for redaction and model serialization.
- Risks: accidental PII logging.
- Dependencies: none.
- Priority: P0.

## 2. Packet timestamping and per-stage latency metrics
- Problem: audio packets only expose sequence ordering, so encode, queue, jitter, and buffer delays cannot be measured.
- Evidence from repository: `AudioPacket` had samples and `seq`; codec had legacy type bytes for presence, PCM16, and Opus.
- Proposed solution: introduce protocol-v2 optional metadata while keeping legacy decode support.
- Scope: sequence, monotonic timestamps, codec id, frame duration, session id, and stream id.
- Out of scope: definitive cross-device one-way latency without clock-offset estimation.
- Acceptance criteria: legacy packets decode; v2 packets expose encode and local queue latency.
- Testing plan: packet parser migration tests.
- Risks: older clients will ignore unknown packet types if v2 is enabled prematurely.
- Dependencies: diagnostics model.
- Priority: P0.

## 3. Wi-Fi peer liveness and reconnect state machine
- Problem: connection lifecycle must not be inferred from UI state or unbounded retry loops.
- Evidence from repository: transfer repositories manage lifecycle independently without a shared state machine.
- Proposed solution: explicit states, events, bounded reconnect, cancellable controller, and disconnect reasons.
- Scope: state transitions and testable retry policy.
- Out of scope: full transport switching UX.
- Acceptance criteria: repeated start is idempotent; reconnects are bounded; success preserves session.
- Testing plan: state-machine unit tests.
- Risks: state mismatch during migration.
- Dependencies: diagnostics model.
- Priority: P0.

## 4. UDP socket rebinding after network changes
- Problem: UDP sockets may be stale after Android network/IP changes.
- Evidence from repository: Wi-Fi repository owns datagram socket and hotspot controller paths.
- Proposed solution: invalidate sockets on network callback/IP change and rebind on selected network.
- Scope: UDP socket lifecycle and receive/send buffer review.
- Out of scope: new encryption.
- Acceptance criteria: IP change recreates socket and increments socket rebind diagnostics.
- Testing plan: socket recreation integration test plus device test.
- Risks: Android API differences.
- Dependencies: connection state machine.
- Priority: P0.

## 5. Hotspot IP and DHCP change handling
- Problem: LocalOnlyHotspot/DHCP changes can leave peers using stale addresses.
- Evidence from repository: hotspot controller and Wi-Fi segment model exist.
- Proposed solution: expire peer addresses, refresh hotspot segment, and reconnect without creating a new room.
- Scope: hotspot lifecycle and peer cache expiry.
- Out of scope: router-managed LAN discovery overhaul.
- Acceptance criteria: peer reconnect uses same room/session IDs after DHCP churn.
- Testing plan: Android device hotspot tests.
- Risks: OEM hotspot behavior variance.
- Dependencies: UDP rebinding.
- Priority: P1.

## 6. Audio jitter-buffer metrics and adaptive tuning
- Problem: jitter target is fixed and tuning is not metric-driven.
- Evidence from repository: playback buffer defaults to 100 ms and drops at a hard cap.
- Proposed solution: expose buffer depth, target, underrun/overrun, late/drop counters, and test low/balanced/stable profiles.
- Scope: instrumentation and debug configuration.
- Out of scope: global frame-duration change without benchmarks.
- Acceptance criteria: metrics show underrun, drop, target, and actual depth.
- Testing plan: buffer unit tests and impairment harness scenarios.
- Risks: too-aggressive tuning can increase choppiness.
- Dependencies: diagnostics model.
- Priority: P1.

## 7. Bluetooth Classic disconnect and reconnect hardening
- Problem: stream closure, parser errors, and duplicate reconnect loops can permanently stall Bluetooth Classic.
- Evidence from repository: RFCOMM uses a length-prefixed framer.
- Proposed solution: validate frame length, handle partial reads, cancel readers/writers, and avoid stale socket reuse.
- Scope: RFCOMM framing and reconnect.
- Out of scope: removing Bluetooth direct.
- Acceptance criteria: invalid frame lengths are rejected and reconnect is single-controller.
- Testing plan: framer/parser and reconnect tests.
- Risks: plugin platform behavior variance.
- Dependencies: state machine.
- Priority: P1.

## 8. BLE audio fallback policy
- Problem: BLE should not be presented as the best continuous voice path.
- Evidence from repository: BLE engine exists beside Classic and Wi-Fi transports.
- Proposed solution: document BLE as fallback/compatibility mode and surface degraded state in UI.
- Scope: policy, capability checks, and UI label.
- Out of scope: BLE removal.
- Acceptance criteria: BLE mode is clearly marked fallback/degraded.
- Testing plan: UI and capability tests.
- Risks: user confusion if messaging is too technical.
- Dependencies: transport capabilities.
- Priority: P1.

## 9. Headset routing and SCO lifecycle validation
- Problem: headset Bluetooth may contend with phone-to-phone Bluetooth transport.
- Evidence from repository: audio session and Bluetooth transport code are separate.
- Proposed solution: validate SCO state, Android audio mode, headset disconnect events, and runtime warnings.
- Scope: Android headset routing diagnostics.
- Out of scope: native audio rewrite.
- Acceptance criteria: diagnostics report SCO state and degraded warning when capabilities conflict.
- Testing plan: physical Android headset matrix.
- Risks: OEM-specific audio routing.
- Dependencies: diagnostics model.
- Priority: P1.

## 10. Transport abstraction
- Problem: audio transport semantics are spread across Wi-Fi, Bluetooth, and WebRTC repositories.
- Evidence from repository: multiple repositories encode/decode the shared Waki packet format separately.
- Proposed solution: introduce VoiceTransport, capabilities, packet/state/health streams, adapters, manager, and fake transport.
- Scope: minimal abstraction over at least two real implementations or documented adapter migration.
- Out of scope: complete transport switching.
- Acceptance criteria: AudioEngine does not need transport-specific knowledge.
- Testing plan: fake transport and manager tests.
- Risks: overengineering or double lifecycle ownership.
- Dependencies: diagnostics and state machine.
- Priority: P2.

## 11. Session identity independent from transport
- Problem: reconnect/transport change must not create new room/session identity.
- Evidence from repository: room and peer identity are currently coupled to connection flows.
- Proposed solution: SessionManager owns session/room/peer IDs independently from transport instances.
- Scope: identity lifecycle.
- Out of scope: backend account identity.
- Acceptance criteria: transport reconnect preserves session and room IDs.
- Testing plan: reconnect and transport fake tests.
- Risks: stale identity leaks across intentional stop/start.
- Dependencies: transport abstraction.
- Priority: P2.

## 12. Native WebRTC media proof of concept
- Problem: custom audio over DataChannel is not native WebRTC media.
- Evidence from repository: WebRTC repository and ICE config exist, but audio packet codec remains custom.
- Proposed solution: feature-flagged two-peer audio track PoC using WebRTC Opus media engine.
- Scope: ICE/STUN, TURN config injection, state and candidate failure diagnostics.
- Out of scope: SFU and production migration.
- Acceptance criteria: existing transport remains fallback if PoC fails.
- Testing plan: two-device/manual WebRTC test.
- Risks: conflict with custom AudioEngine.
- Dependencies: transport abstraction and TURN config.
- Priority: P2.

## 13. TURN configuration and failure testing
- Problem: relay credentials must not be hardcoded and failure modes need metrics.
- Evidence from repository: ICE config exists.
- Proposed solution: load TURN from secure config/environment and emit candidate failure diagnostics.
- Scope: config plumbing and failure cases.
- Out of scope: operating a TURN service.
- Acceptance criteria: no secrets in code; missing TURN degrades gracefully.
- Testing plan: config tests and manual relay tests.
- Risks: operational misconfiguration.
- Dependencies: WebRTC PoC.
- Priority: P2.

## 14. Local LAN encrypted media proof of concept
- Problem: MVP LAN media encryption status is unclear.
- Evidence from repository: shared packet codec does not document encryption.
- Proposed solution: separate security PoC or document current MVP limitation if no secure infrastructure exists.
- Scope: local LAN encryption feasibility.
- Out of scope: rolling custom crypto without review.
- Acceptance criteria: threat model and PoC plan exist.
- Testing plan: crypto review and interoperability tests.
- Risks: unsafe crypto design.
- Dependencies: transport abstraction.
- Priority: P3.

## 15. Network impairment test harness
- Problem: reliability changes need reproducible packet loss, jitter, reordering, duplicate, and disconnect scenarios.
- Evidence from repository: no dedicated impairment layer is present.
- Proposed solution: debug/test-only impairment adapter around packet streams.
- Scope: LAN healthy, 2/5/10% loss, 50 ms jitter, 5 s disconnect, IP change, socket recreation, headset disconnect, app background/foreground.
- Out of scope: production impairment.
- Acceptance criteria: tests can inject impairment deterministically.
- Testing plan: unit tests with seeded random.
- Risks: accidentally enabling in release.
- Dependencies: transport abstraction.
- Priority: P2.

## 16. Multi-device test matrix
- Problem: Bluetooth, SCO, hotspot, and Wi-Fi behavior is device/OEM-dependent.
- Evidence from repository: Android, iOS, WebRTC, Wi-Fi, Classic, and BLE code paths exist.
- Proposed solution: define matrix covering Android versions, iOS, chipsets, hotspot, headset, and LAN conditions.
- Scope: manual and automated matrix documentation.
- Out of scope: buying or provisioning devices.
- Acceptance criteria: release checklist lists required physical-device scenarios.
- Testing plan: run matrix before enabling new transport defaults.
- Risks: incomplete coverage hides OEM bugs.
- Dependencies: diagnostics screen/export.
- Priority: P2.
