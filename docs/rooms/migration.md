# Saved Room migration and compatibility

Tark's existing `ChannelId` remains a session/wire compatibility alias. It is a
six-character, 24-bit value that is explicitly not a secret and is not durable
room identity. `ChannelMembership` also remains session-scoped so existing
quick channel, hotspot, Bluetooth and guest entry paths keep their current wire
behavior while the saved-room UX is migrated incrementally.

New saved rooms always receive a fresh high-entropy `RoomId` and durable local
`RoomMemberId`. Neither value is derived from `ChannelId`, IP address, SSID,
Bluetooth address, display name or the device currently hosting the transport.
A later start-session adapter may allocate/adopt a `ChannelId` for the live wire
session, but rotating that alias or replacing the transport must not change the
saved `RoomId` or membership.

Persistence schema v1 stores each room under a separate key plus a small RoomId
index. Unsupported or corrupt individual records are skipped rather than
causing all saved rooms to be discarded. No hotspot credentials, socket/native
handles, transient presence or transport roles are persisted.

There is intentionally no automatic conversion of an old six-character channel
into permanent membership: old channels did not contain enough durable identity
or authorization data to infer a safe Room. Existing users can continue the
legacy/session flow, or explicitly create/save a Room through the new UX when
that migration surface lands.
