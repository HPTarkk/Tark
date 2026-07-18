import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 4 — the payoff: with the radio powered and transmitting below, this
/// panel confirms the operator's loadout (callsign + channel) and stamps the
/// unit READY, a holographic gloss sweeping across it like a laminated ID.
class ReadyStep extends StatelessWidget {
  final Animation<double> reveal;

  /// 0..1 gloss-glint loop shared with the page CTA.
  final Animation<double> shimmer;

  const ReadyStep({super.key, required this.reveal, required this.shimmer});

  String _modeLabel(AppLocalizations s, TransferMode mode) => switch (mode) {
    TransferMode.wifi || TransferMode.hotspot => s.transport_wifi_hotspot,
    TransferMode.bluetooth => s.transport_bluetooth,
    TransferMode.guest => s.transport_guest,
  };

  IconData _modeIcon(TransferMode mode) => switch (mode) {
    TransferMode.wifi || TransferMode.hotspot => Icons.wifi_rounded,
    TransferMode.bluetooth => Icons.bluetooth_rounded,
    TransferMode.guest => Icons.qr_code_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      builder: (context, state) {
        final name = state.name.trim();
        return StaggeredItem(
          reveal: reveal,
          index: 0,
          count: 1,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _HoloGloss(
                shimmer: shimmer,
                child: HudPanel(
                  header: s.onboarding_ready_title,
                  status: 'ON AIR',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Readout(
                        label: '‹CALLSIGN›',
                        child: Text(
                          name.isEmpty ? '—' : name.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Onb.amber,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _Readout(
                        label: '‹CHANNEL›',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_modeIcon(state.mode), size: 15, color: Onb.text),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                _modeLabel(s, state.mode),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Onb.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Tip(text: s.onboarding_tip_vox),
                      const SizedBox(height: 8),
                      _Tip(text: s.onboarding_tip_settings),
                    ],
                  ),
                ),
              ),
              PositionedDirectional(
                top: -12,
                end: 12,
                child: _ReadyStamp(reveal: reveal),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A labelled console readout line: dim mono label on the left, value block
/// on the right, split by a dotted leader.
class _Readout extends StatelessWidget {
  final String label;
  final Widget child;

  const _Readout({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: Onb.amber.withAlpha(160),
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Align(alignment: AlignmentDirectional.centerEnd, child: child),
        ),
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  final String text;
  const _Tip({required this.text});
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4),
          width: 4,
          height: 4,
          color: Onb.amber,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Onb.textDim, fontSize: 11.5, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// The payoff moment: a rubber-stamp "READY" seal that slams onto the panel —
/// riding the tail of the beat's reveal so it lands after the panel has
/// assembled, overshooting slightly like a real stamp.
class _ReadyStamp extends StatelessWidget {
  final Animation<double> reveal;

  const _ReadyStamp({required this.reveal});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final slam = CurvedAnimation(
      parent: reveal,
      curve: const Interval(0.72, 1.0, curve: Curves.easeOutBack),
    );
    return AnimatedBuilder(
      animation: slam,
      builder: (_, child) {
        final t = slam.value;
        if (t <= 0) return const SizedBox.shrink();
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: -0.16,
            child: Transform.scale(scale: 2.2 - 1.2 * t, child: child),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: Onb.ink.withAlpha(210),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Onb.amber, width: 2),
          boxShadow: [
            BoxShadow(color: Onb.amber.withAlpha(80), blurRadius: 12),
          ],
        ),
        child: Text(
          s.onboarding_stamp_ready,
          style: TextStyle(
            color: Onb.amber,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: isFa ? 0.5 : 3,
          ),
        ),
      ),
    );
  }
}

/// Periodic holographic gloss across the operator panel — a soft diagonal
/// light band sweeping over part of the loop. Rendered srcATop so it only
/// tints the panel's own pixels.
class _HoloGloss extends StatelessWidget {
  final Animation<double> shimmer;
  final Widget child;

  const _HoloGloss({required this.shimmer, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: shimmer,
      child: child,
      builder: (_, prebuilt) {
        final glossT = Curves.easeInOut.transform(
          ((shimmer.value - 0.55) / 0.45).clamp(0.0, 1.0),
        );
        final dx = -1.8 + 3.6 * glossT;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(dx - 0.7, -1),
            end: Alignment(dx + 0.7, 1),
            colors: [
              const Color(0x00FFFFFF),
              Colors.white.withAlpha(30),
              const Color(0x00FFFFFF),
            ],
          ).createShader(rect),
          child: prebuilt,
        );
      },
    );
  }
}
