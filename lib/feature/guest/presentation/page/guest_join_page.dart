import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
// Direct file imports (not the transfer barrel) — see GuestWebClient.
import '../../../transfer/data/webrtc/sdp_codec.dart';
import '../../../transfer/domain/entity/guest_link_state.dart';
import '../../data/guest_web_client.dart';
import '../manager/guest_session_cubit.dart';
import '../widget/guest_console.dart';
import '../widget/guest_settings_toggles.dart';

/// The whole guest journey in one page:
///   opened without an offer  → "scan the host's QR" instructions
///   offer in the URL fragment → reply QR ("show this to the host")
///   channel opens             → tap-to-start-audio (Safari gesture rule)
///   live                      → walkie console with the talk orb
class GuestJoinPage extends StatefulWidget {
  const GuestJoinPage({super.key});

  @override
  State<GuestJoinPage> createState() => _GuestJoinPageState();
}

class _GuestJoinPageState extends State<GuestJoinPage> {
  final GuestWebClient _client = GuestWebClient();
  GuestSessionCubit? _session;

  String? _answerPayload;
  GuestLinkState _link = GuestLinkState.idle;
  bool _noOffer = false;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _client.linkState.listen((link) {
      if (mounted) setState(() => _link = link);
    });
    _answer();
  }

  Future<void> _answer() async {
    final fragment = Uri.base.fragment;
    final payload =
        fragment.startsWith('o=') ? extractSdpPayload(fragment) : null;
    if (payload == null || payload.isEmpty) {
      setState(() => _noOffer = true);
      return;
    }
    try {
      final answer = await _client.answerOffer(payload);
      if (mounted) setState(() => _answerPayload = answer);
    } catch (_) {
      // _link already moved to failed via the stream.
    }
  }

  @override
  void dispose() {
    _session?.close();
    if (!_left) _client.dispose();
    super.dispose();
  }

  /// Leave the channel: stop the mic (dispose the session) and tear the peer
  /// link down. Terminal for this page load — rejoining needs a fresh invite
  /// from the host, which the guest reopens by scanning again.
  Future<void> _leave() async {
    await _session?.close();
    _session = null;
    await _client.dispose();
    if (mounted) setState(() => _left = true);
  }

  @override
  Widget build(BuildContext context) {
    final isConsole = _phaseKey == 'connected';
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Center when the content is short (QR / messages), scroll when
            // it's tall (the full console).
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            20, isConsole ? 16 : 60, 20, 28),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          child: KeyedSubtree(
                            key: ValueKey(_phaseKey),
                            child: _body(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // The console carries its own header toggles; only float them on
            // the QR / message phases.
            if (!isConsole)
              const PositionedDirectional(
                top: 12,
                end: 16,
                child: GuestSettingsToggles(),
              ),
          ],
        ),
      ),
    );
  }

  String get _phaseKey {
    if (_left) return 'left';
    if (_noOffer) return 'no-offer';
    if (_link == GuestLinkState.failed) return 'failed';
    if (_link == GuestLinkState.connected) return 'connected';
    if (_answerPayload != null) return 'reply';
    return 'loading';
  }

  Widget _body(BuildContext context) {
    final s = context.getString;
    if (_left) {
      return _CenteredMessage(
        icon: Icons.check_circle_outline_rounded,
        title: s.guest_web_left_title,
        text: s.guest_web_left_text,
      );
    }
    if (_noOffer) {
      return _CenteredMessage(
        icon: Icons.qr_code_scanner_rounded,
        title: s.guest_web_scan_title,
        text: s.guest_web_scan_text,
      );
    }
    if (_link == GuestLinkState.failed) {
      return _CenteredMessage(
        icon: Icons.error_outline_rounded,
        title: s.guest_web_failed_title,
        text: s.guest_web_failed_text,
      );
    }
    if (_link == GuestLinkState.connected) {
      final session = _session ??= GuestSessionCubit(_client);
      return BlocProvider.value(
        value: session,
        child: _SessionConsole(onLeave: _leave),
      );
    }
    if (_answerPayload != null) {
      return _ReplyQr(payload: _answerPayload!);
    }
    return Center(child: CircularProgressIndicator(color: AppColors.amber));
  }
}

// ── Reply QR ────────────────────────────────────────────────────────────────

class _ReplyQr extends StatelessWidget {
  final String payload;

  const _ReplyQr({required this.payload});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.amber.withAlpha(18),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.amber.withAlpha(120)),
          ),
          child: Text(
            context.getString.guest_web_reply_chip,
            style: TextStyle(
              color: AppColors.amber,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.8,
            ),
          ),
        ),
        const SizedBox(height: 18),
        GlowingQrCard(data: 'a=$payload', size: 250),
        const SizedBox(height: 20),
        Text(
          context.getString.guest_web_reply_title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.getString.guest_web_reply_hint,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
        ),
        const SizedBox(height: 20),
        const _WaitingDots(),
      ],
    );
  }
}

/// Three dots breathing in sequence — "the host hasn't scanned yet".
class _WaitingDots extends StatefulWidget {
  const _WaitingDots();

  @override
  State<_WaitingDots> createState() => _WaitingDotsState();
}

class _WaitingDotsState extends State<_WaitingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 7),
            Opacity(
              opacity: 0.25 +
                  0.75 *
                      (0.5 +
                          0.5 *
                              sin(2 * pi * (_controller.value - i * 0.18))),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.amber,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Live session ────────────────────────────────────────────────────────────

class _SessionConsole extends StatelessWidget {
  final Future<void> Function() onLeave;

  const _SessionConsole({required this.onLeave});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) =>
          p.audioStarted != c.audioStarted ||
          p.audioStarting != c.audioStarting,
      builder: (context, state) {
        // Before mic is unlocked, the tap-to-start gate is centered; once
        // audio flows, the full walkie-style console takes over.
        if (!state.audioStarted) {
          return _StartAudioButton(starting: state.audioStarting);
        }
        return GuestConsole(onLeave: () => onLeave());
      },
    );
  }
}

class _StartAudioButton extends StatelessWidget {
  final bool starting;

  const _StartAudioButton({required this.starting});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.4, end: 1.0),
          duration: const Duration(milliseconds: 450),
          curve: Curves.elasticOut,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.green.withAlpha(26),
              border: Border.all(color: AppColors.green, width: 2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.green.withAlpha(70),
                  blurRadius: 26,
                ),
              ],
            ),
            child: Icon(Icons.check_rounded, color: AppColors.green, size: 42),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.getString.guest_web_connected,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.getString.guest_web_enable_audio,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 26),
        GestureDetector(
          onTap: starting
              ? null
              : () => context.read<GuestSessionCubit>().startAudio(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 17),
            decoration: BoxDecoration(
              color: AppColors.amber.withAlpha(starting ? 12 : 25),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.amber.withAlpha(starting ? 70 : 150),
                width: 2,
              ),
              boxShadow: starting
                  ? null
                  : [
                      BoxShadow(
                        color: AppColors.amber.withAlpha(46),
                        blurRadius: 22,
                      ),
                    ],
            ),
            child: starting
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: AppColors.amber,
                      strokeWidth: 2,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.headset_mic_rounded,
                          color: AppColors.amber, size: 19),
                      const SizedBox(width: 10),
                      Text(
                        context.getString.guest_web_start_audio,
                        style: TextStyle(
                          color: AppColors.amber,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amber.withAlpha(18),
            border: Border.all(color: AppColors.amber.withAlpha(120)),
          ),
          child: Icon(icon, color: AppColors.amber, size: 38),
        ),
        const SizedBox(height: 20),
        Text(
          title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}
