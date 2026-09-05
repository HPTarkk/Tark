# Room-first automatic transport policy

Tark's primary user model is a durable Room, not a network setup flow. Normal users should never need to decide whether a phone is a hotspot host, joiner, Wi-Fi peer, or Bluetooth peer.

## Primary behavior

1. Join the durable Room first.
2. Prefer an already-proven shared LAN when bidirectional peer reachability is confirmed.
3. If shared LAN cannot be proven quickly, fall back automatically to Tark-managed hotspot transport.
4. Prefer the Room creator as the first hotspot candidate while they are eligible; this is a transport policy hint, never Room ownership.
5. If that candidate is unavailable, use the deterministic Room transport election to choose the next eligible member.
6. Keep a healthy attachment sticky. Do not switch transport merely because another network later becomes visible.
7. Fail over only after the current attachment is actually considered failed by the failover state machine; stale callbacks from older epochs must not replace a healthy attachment.

## UX invariants

- Do not show “same network”, hotspot/client role, SSID, IP address, or Wi-Fi requirements in the normal Room lobby.
- The Room lobby shows people and actions: invite and start/talk.
- Pending invite seats are authorization bookkeeping, not members. They do not change the normal member count and are not rendered as empty people in the primary lobby.
- Manual Wi-Fi QR, SSID/password and transport diagnostics belong only in explicit recovery/troubleshooting surfaces.
- Connection preparation is represented generically (for example, “preparing” / “reconnecting”), never as instructions to manually arrange a network.

## Shared LAN definition

`sharedLanUsable` is true only when peer reachability has been proven for the current Room/session attachment. Local Wi-Fi association, matching SSID, or an available Wi-Fi interface alone is not proof that Room peers can reach each other.

## Stability

A healthy hotspot/LAN attachment stays in place. New network availability must not trigger opportunistic handover. Host replacement uses existing epoch fencing and deterministic failover and is reserved for real attachment loss or an explicit controlled handover policy.
