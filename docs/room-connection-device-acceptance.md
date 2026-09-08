# Room connection physical acceptance gate

This runbook is the final manual gate for the proximity Room flow. CI proves the deterministic state-machine races; this document proves the Android radios, OS network binding, authenticated Room proof, and audio path on real devices.

## Required build evidence

Use the **same device-test or release build commit** on every phone in one run.

Before testing, export/open Diagnostics once and verify the session header contains a line shaped like:

```text
build: version=... commit=<40 lowercase hex chars> dirty=clean channel=... builtAt=...
```

A run is invalid when `commit=unknown`, the commit is not 40 hex characters, the two phones report different commits, or the build is marked dirty. Do not use an invalid run as release evidence.

Room readiness lines also contain a credential-free correlation id:

```text
room: readiness corr=rc-1234abcd attempt=1 stage=wait_started attachment=1
```

The same durable Room produces the same `corr=rc-...` on each phone without logging the raw Room id, SSID, IP address, Bluetooth address, or display name. `attempt` is local and may differ after a retry; pair exported logs primarily by `corr` and build commit.

## A55 ↔ A53 five-run gate

Perform **five clean runs**. Start each run from no active Tark Room transport. Normal users must never manually choose Host, Join, SSID, IP, or scan a second QR.

1. On phone A, create a Room.
2. On phone B, join that Room through the nearby Bluetooth join flow.
3. Before starting audio, verify both phones show the same confirmed roster. An invited/pending seat must not masquerade as a connected member.
4. Press **Start** on both phones as close together as practical. Across the five runs include at least one same-phone double tap, one cancel/retry, and one background/resume while connection is preparing.
5. If the phones are not already on a proven shared LAN, verify only the deterministic elected side creates the hotspot. The other side must follow automatically. Two independent hotspots fail the run.
6. Do not treat Wi-Fi association, hotspot creation, or a local socket bind as Connected. Each successful device log must progress through the correlated readiness evidence:
   - `stage=wait_started`
   - `stage=transport_ready`
   - `stage=peer_proof_observed`
   - `stage=ready`
7. Verify the UI reaches Connected only after the signed peer proof stage.
8. Verify bidirectional audio: A → B and B → A.
9. Export the diagnostic log from both phones immediately after the run and keep the pair together.

### Failure-stage lookup

Use the last correlated readiness stage in each log pair:

| Stage | Meaning |
| --- | --- |
| `transport_bind_timeout` | Selected-network/process binding, socket/control bind, or transport-health readiness did not complete. |
| `peer_proof_missing` | The carrier became healthy but authenticated Room hello/ack proof from a durable peer did not arrive on the current attachment. |
| `stale_epoch` | A cancelled/restarted attempt fenced a delayed callback. This is expected protection; the new attempt must use a newer local attempt number. |
| `transport_plan_mismatch` | The already-proven carrier disagreed with deterministic Room transport/role election. Do not enter live audio. |
| `coordinator_rejected` | The coordinator refused the final state transition; inspect the preceding correlated readiness lines. |
| `transport_setup` | Composition/native transport setup threw before verified live entry. |

A failure pair is actionable when both logs include an exact build commit and the Room correlation id. Never copy SSIDs, hotspot passwords, IPs, or private keys into an issue.

## Required race coverage across the five runs

- simultaneous Start on both phones;
- double tap on Start;
- cancel while preparing, followed by retry;
- background/resume while preparing;
- delayed/stale native completion after cancel/retry;
- receipt delivery/retry without duplicating the durable member;
- deterministic hotspot host election.

CI covers the same state-machine classes deterministically. The physical gate exists to catch Android/OEM behavior that unit and widget tests cannot reproduce.

## Third-device gate before declaring group support

Do not declare group Room audio supported from A55 ↔ A53 success alone.

Add a third physical phone and verify:

1. all three phones show the same confirmed durable roster;
2. all three logs carry the same Room `corr=rc-...` and exact build commit;
3. transport election converges on one common carrier/host when hotspot fallback is needed;
4. no phone forms an independent pairwise Room that merely looks connected;
5. authenticated peer proof is observed on the common active attachment;
6. the intended group audio directions work on that common Room/session.

Keep issue #206 open until the five A55 ↔ A53 runs and this third-device gate have been recorded. Merging the CI harness does **not** claim that these physical checks were performed.

## Evidence record

| Run | Build commit | Room corr | Scenario | Roster equal | One carrier/host | Signed proof | A→B | B→A | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 |  |  | simultaneous Start |  |  |  |  |  |  |
| 2 |  |  | double tap |  |  |  |  |  |  |
| 3 |  |  | cancel/retry |  |  |  |  |  |  |
| 4 |  |  | background/resume |  |  |  |  |  |  |
| 5 |  |  | stale callback/retry |  |  |  |  |  |  |

Attach/export both phone logs for any failed run and record the exact failed stage rather than a generic "did not connect" description.
