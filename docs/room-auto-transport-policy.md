# Room-first automatic transport policy

Tark's primary user model is a durable Room, not a network setup flow. Normal users should never need to decide whether a phone is a hotspot host, joiner, Wi-Fi peer, or Bluetooth peer.

## Primary behavior

1. Join the durable Room first.
2. Prefer an already-proven shared LAN when bidirectional peer reachability is confirmed.
3. If shared LAN cannot be proven quickly, fall back automatically to Tark-managed hotspot transport.
4. For the first hotspot of a proximity hand-off, the phone that showed the QR raises it and the scanning phone joins. Both ends of the Bluetooth socket know which side they are on, so they agree without an election — and unlike "the Room creator", the choice is always one of the two phones actually standing there. This is a transport hint, never Room ownership.
5. If that candidate is unavailable, use the deterministic Room transport election to choose the next eligible member.
6. Keep a healthy attachment sticky. Do not switch transport merely because another network later becomes visible.
7. Fail over only after the current attachment is actually considered failed by the failover state machine; stale callbacks from older epochs must not replace a healthy attachment.

A scan is the start. Once the joiner's membership receipt is confirmed, neither phone waits for a second tap: the scanner goes straight to connecting, and the issuer's lobby starts connecting when the new member arrives over its own hand-off. Both ends wait up to 60 s for each other, which covers the host bringing its access point up and the joiner answering Android's "connect to this network?" prompt.

When Start is pressed with a proximity hand-off open, the hand-off plans the hotspot. Without one — after a restart, or once the socket has closed — there is nothing to arrange, so the link the phone already holds is tried as it is, and the signed peer proof decides whether it reaches anybody. Only when that fails does the lobby offer connecting the phones by hand, beside the failure message. An unresolved probe is never treated as proof that a hotspot is needed.

## UX invariants

- Do not show “same network”, hotspot/client role, SSID, IP address, or Wi-Fi requirements in the normal Room lobby.
- The Room lobby shows people and actions: invite and start/talk. Start is not offered in a Room of one — it could only fail.
- Before Start, other members' rows make no claim about their phones; status appears once connecting begins.
- Manual connection is offered only beside a failed Start that the automatic path could not get past.
- Pending invite seats are authorization bookkeeping, not members. They do not change the normal member count and are not rendered as empty people in the primary lobby.
- Manual Wi-Fi QR, SSID/password and transport diagnostics belong only in explicit recovery/troubleshooting surfaces.
- Connection preparation is represented generically (for example, “preparing” / “reconnecting”), never as instructions to manually arrange a network.

## Shared LAN definition

`sharedLanUsable` is true only when peer reachability has been proven for the current Room/session attachment. Local Wi-Fi association, matching SSID, or an available Wi-Fi interface alone is not proof that Room peers can reach each other.

## Stability

A healthy hotspot/LAN attachment stays in place. New network availability must not trigger opportunistic handover. Host replacement uses existing epoch fencing and deterministic failover and is reserved for real attachment loss or an explicit controlled handover policy.
