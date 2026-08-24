enum InRoomInviteKind {
  roomQr,
  roomCode,
  hotspotWifi,
  share,
  guestLink,
}

class InRoomInviteContext {
  const InRoomInviteContext({
    required this.isTransportHost,
    required this.hasRoomQr,
    required this.hasRoomCode,
    required this.hasHotspotCredentials,
    required this.hasGuestLink,
    this.isRecovering = false,
  });

  final bool isTransportHost;
  final bool hasRoomQr;
  final bool hasRoomCode;
  final bool hasHotspotCredentials;
  final bool hasGuestLink;
  final bool isRecovering;
}

class InRoomInviteOption {
  const InRoomInviteOption({
    required this.kind,
    required this.enabled,
    this.reason,
  });

  final InRoomInviteKind kind;
  final bool enabled;
  final String? reason;
}

/// Decides which invite surfaces may be exposed from a live room.
///
/// This deliberately operates on capability booleans rather than credentials
/// or tokens. Host-only network secrets never enter ordinary-member policy
/// output, and temporary hotspot recovery can disable a stale Wi-Fi QR without
/// affecting the logical room QR/code/share actions.
class InRoomInvitePolicy {
  const InRoomInvitePolicy();

  List<InRoomInviteOption> options(InRoomInviteContext context) {
    final result = <InRoomInviteOption>[];

    if (context.hasRoomQr) {
      result.add(
        const InRoomInviteOption(
          kind: InRoomInviteKind.roomQr,
          enabled: true,
        ),
      );
    }
    if (context.hasRoomCode) {
      result.add(
        const InRoomInviteOption(
          kind: InRoomInviteKind.roomCode,
          enabled: true,
        ),
      );
    }

    // Hotspot credentials are transport attachment details, never room
    // identity. Only the current transport host may expose them, and a QR from
    // before a rehost is disabled while recovery is replacing credentials.
    if (context.isTransportHost && context.hasHotspotCredentials) {
      result.add(
        InRoomInviteOption(
          kind: InRoomInviteKind.hotspotWifi,
          enabled: !context.isRecovering,
          reason: context.isRecovering ? 'hotspot_recovering' : null,
        ),
      );
    }

    if (context.hasRoomQr || context.hasRoomCode || context.hasGuestLink) {
      result.add(
        const InRoomInviteOption(
          kind: InRoomInviteKind.share,
          enabled: true,
        ),
      );
    }
    if (context.hasGuestLink) {
      result.add(
        const InRoomInviteOption(
          kind: InRoomInviteKind.guestLink,
          enabled: true,
        ),
      );
    }

    return List.unmodifiable(result);
  }
}
