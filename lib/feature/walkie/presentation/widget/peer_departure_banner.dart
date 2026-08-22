import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';

/// A brief, self-dismissing "so-and-so left" toast for a peer who announced
/// their own departure (see `PresencePacket.isLeaving`).
///
/// Distinct on purpose from every other departure, which has always been
/// noticed only by silence — a peer simply ages out of the roster past
/// `ChannelRoster.staleAfterSeconds` with an SFX cue and nothing to look at.
/// A graceful goodbye deserves a moment; an inferred one does not, since
/// nothing here can tell "gone for good" from "still arriving" until the
/// timeout has already spoken for it.
///
/// Reuses [ConnectionHealthBanner]'s motion vocabulary rather than inventing
/// a new one: `AnimatedSize` for the show/collapse, the same ~300ms
/// `easeOutCubic`, and a flash-then-collapse `Timer`.
class PeerDepartureBanner extends StatefulWidget {
  const PeerDepartureBanner({super.key, required this.departure});

  /// Who left and when. A new [DateTime] — even naming the same person twice
  /// — retriggers the toast; null keeps it collapsed.
  final ({String name, DateTime at})? departure;

  @override
  State<PeerDepartureBanner> createState() => _PeerDepartureBannerState();
}

class _PeerDepartureBannerState extends State<PeerDepartureBanner> {
  // Long enough to read a name, short enough not to linger over a roster
  // that has already moved on.
  static const _visibleFor = Duration(milliseconds: 2200);

  Timer? _dismissTimer;
  bool _visible = false;

  @override
  void didUpdateWidget(PeerDepartureBanner old) {
    super.didUpdateWidget(old);
    final at = widget.departure?.at;
    if (at == null || at == old.departure?.at) return;
    _dismissTimer?.cancel();
    setState(() => _visible = true);
    _dismissTimer = Timer(_visibleFor, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final departure = widget.departure;
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: (!_visible || departure == null)
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _toast(context, departure.name),
            ),
    );
  }

  Widget _toast(BuildContext context, String name) {
    final s = context.getString;
    // Dim amber, not the full accent and not red — a goodbye is information,
    // not an alert, so it should not read as alarming next to a real link
    // failure.
    final accent = AppColors.amberDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(110)),
      ),
      child: Row(
        children: [
          // Dimmed, not lit — the avatar itself says "gone" before the text
          // does, the same grey ring the roster gives an inactive peer.
          AppAvatar(name: name, isActive: false, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.peer_left_channel(name),
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.wifi_tethering_off_rounded, size: 15, color: accent),
        ],
      ),
    );
  }
}
