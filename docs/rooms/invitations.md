# Room invitations

Room invitations are bearer capabilities for the durable Room model. The six-digit display code is only a verbal/check value; it is never sufficient to discover a room or authorize membership.

The versioned QR/link payload carries a stable `RoomId`, a random invitation id, a 256-bit random secret, invitation policy, expiry, and an optional transport-bootstrap section. Temporary Wi-Fi/hotspot data stays in that separate transport section, so credential rotation cannot rename the Room or change durable membership.

Two policies are supported by the contract: reusable trusted-membership invitations and single-ride guest invitations. Single-ride invitations are recorded as redeemed and fail closed on replay. Any invitation can be revoked by id. The replay/revocation ledger intentionally persists identifiers only, never bearer secrets.

## Offline revocation boundary

Tark does not pretend that revocation can propagate instantly between devices that are completely disconnected. Revocation is authoritative on a peer once that peer has received the updated ledger state through a future room/control synchronization path. A fully offline peer holding an older capability cannot learn about newer revocation until communication is restored. This is an explicit consistency boundary, not a reason to treat the short room code as a secret.

Malformed payloads, unsupported versions, invalid expiry windows, invalid high-entropy fields, and inconsistent display checks fail closed. Logs and diagnostics must record only policy/result reason codes and invitation identifiers when needed; they must never log the invitation secret or full encoded payload.
