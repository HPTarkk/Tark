import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
// Direct file imports (not the transfer barrel) — see GuestWebClient.
import '../../../transfer/data/webrtc/sdp_codec.dart';
import '../../../transfer/domain/entity/guest_link_state.dart';
import '../../data/guest_web_client.dart';
import '../manager/guest_session_cubit.dart';

/// The whole guest journey in one page:
///   opened without an offer  → "scan the host's QR" instructions
///   offer in the URL fragment → reply QR ("show this to the host")
///   channel opens             → tap-to-start-audio (Safari gesture rule)
///   live                      → walkie console with the talk orb
///
/// English-only on purpose: guests are ephemeral visitors, and skipping
/// l10n keeps the web bundle lean.
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
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: KeyedSubtree(
                  key: ValueKey(_phaseKey),
                  child: _body(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _phaseKey {
    if (_noOffer) return 'no-offer';
    if (_link == GuestLinkState.failed) return 'failed';
    if (_link == GuestLinkState.connected) return 'connected';
    if (_answerPayload != null) return 'reply';
    return 'loading';
  }

  Widget _body() {
    if (_noOffer) {
      return const _CenteredMessage(
        icon: Icons.qr_code_scanner_rounded,
        title: 'Scan to join',
        text:
            'Open this page by scanning the invite QR code on the host\'s '
            'phone with your camera — the link carries the connection.',
      );
    }
    if (_link == GuestLinkState.failed) {
      return const _CenteredMessage(
        icon: Icons.error_outline_rounded,
        title: 'Link failed',
        text:
            'The connection could not be established. Ask the host to create '
            'a new invite and scan it again (both devices must be on the '
            'same WiFi).',
      );
    }
    if (_link == GuestLinkState.connected) {
      final session = _session ??= GuestSessionCubit(_client);
      return BlocProvider.value(
        value: session,
        child: const _SessionConsole(),
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
            'STEP 2 — REPLY CODE',
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
          'Show this code to the host phone',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'On the host: tap "SCAN REPLY CODE" and point the camera here.',
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
  const _SessionConsole();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      builder: (context, state) {
        if (!state.audioStarted) {
          return _StartAudioButton(starting: state.audioStarting);
        }
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!state.linkUp)
              Container(
                margin: const EdgeInsets.only(bottom: 22),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.red.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.red.withAlpha(120)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        color: AppColors.red,
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'LINK LOST',
                      style: TextStyle(
                        color: AppColors.red,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            _TalkOrb(
              hostTalking: state.hostTalking,
              meTalking: state.isTalking,
              muted: state.muted,
            ),
            const SizedBox(height: 26),
            Text(
              state.hostName.isEmpty ? 'Connected' : state.hostName,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              !state.linkUp
                  ? 'Link lost — waiting...'
                  : state.hostTalking
                      ? 'Talking...'
                      : state.isTalking
                          ? 'You are on air'
                          : 'Standing by',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 34),
            GestureDetector(
              onTap: () => context.read<GuestSessionCubit>().toggleMute(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
                decoration: BoxDecoration(
                  color: (state.muted ? AppColors.red : AppColors.amber)
                      .withAlpha(24),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: (state.muted ? AppColors.red : AppColors.amber)
                        .withAlpha(140),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      state.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      color: state.muted ? AppColors.red : AppColors.amber,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      state.muted ? 'UNMUTE' : 'MUTE',
                      style: TextStyle(
                        color: state.muted ? AppColors.red : AppColors.amber,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
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
          'Connected!',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap below to enable your microphone and speaker.',
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
                        'START AUDIO',
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

/// Big status orb with ripple rings while audio flows: amber when the host
/// talks, green when you transmit, red ring when muted.
class _TalkOrb extends StatefulWidget {
  final bool hostTalking;
  final bool meTalking;
  final bool muted;

  const _TalkOrb({
    required this.hostTalking,
    required this.meTalking,
    required this.muted,
  });

  @override
  State<_TalkOrb> createState() => _TalkOrbState();
}

class _TalkOrbState extends State<_TalkOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.muted
        ? AppColors.red
        : widget.hostTalking
            ? AppColors.amber
            : widget.meTalking
                ? AppColors.green
                : AppColors.border;
    final active = (widget.hostTalking || widget.meTalking) && !widget.muted;
    return SizedBox(
      width: 210,
      height: 210,
      child: AnimatedBuilder(
        animation: _ripple,
        builder: (context, child) => CustomPaint(
          painter: active
              ? _RipplePainter(t: _ripple.value, color: color)
              : null,
          child: child,
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withAlpha(active ? 36 : 14),
              border: Border.all(color: color, width: 2),
              boxShadow: active
                  ? [BoxShadow(color: color.withAlpha(90), blurRadius: 34)]
                  : null,
            ),
            child: Icon(
              widget.muted
                  ? Icons.mic_off_rounded
                  : widget.hostTalking
                      ? Icons.volume_up_rounded
                      : Icons.mic_rounded,
              color:
                  color == AppColors.border ? AppColors.textSecondary : color,
              size: 44,
            ),
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final double t;
  final Color color;

  _RipplePainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    for (var k = 0; k < 2; k++) {
      final phase = (t + k / 2) % 1.0;
      final radius = 66 + phase * (maxRadius - 66);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withAlpha(((1 - phase) * 100).toInt()),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t || old.color != color;
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
