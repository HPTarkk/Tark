import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/theme/app_colors.dart';
// Direct file imports (not the transfer barrel) — see GuestWebClient.
import '../../../transfer/data/webrtc/sdp_codec.dart';
import '../../../transfer/domain/entity/guest_link_state.dart';
import '../../data/guest_web_client.dart';
import '../manager/guest_session_cubit.dart';

/// The whole guest journey in one page:
///   opened without an offer  → "scan the host's QR" instructions
///   offer in the URL fragment → reply QR ("show this to the host")
///   channel opens             → tap-to-start-audio (Safari gesture rule)
///   live                      → minimal session console
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
    final payload = fragment.startsWith('o=')
        ? extractSdpPayload(fragment)
        : null;
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
              child: _body(),
            ),
          ),
        ),
      ),
    );
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
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(color: AppColors.amber.withAlpha(40), blurRadius: 24),
            ],
          ),
          child: QrImageView(
            data: 'a=$payload',
            version: QrVersions.auto,
            size: 260,
            gapless: true,
          ),
        ),
        const SizedBox(height: 22),
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
        const SizedBox(height: 18),
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            color: AppColors.amber,
            strokeWidth: 2,
          ),
        ),
      ],
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
              child: Container(
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
        Icon(Icons.headset_mic_rounded, color: AppColors.amber, size: 44),
        const SizedBox(height: 18),
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
        const SizedBox(height: 24),
        GestureDetector(
          onTap: starting
              ? null
              : () => context.read<GuestSessionCubit>().startAudio(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.amber.withAlpha(25),
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: AppColors.amber.withAlpha(140), width: 2),
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
                : Text(
                    'START AUDIO',
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// Big status orb: amber glow when the host talks, red ring when muted,
/// green pulse when transmitting.
class _TalkOrb extends StatelessWidget {
  final bool hostTalking;
  final bool meTalking;
  final bool muted;

  const _TalkOrb({
    required this.hostTalking,
    required this.meTalking,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final color = muted
        ? AppColors.red
        : hostTalking
            ? AppColors.amber
            : meTalking
                ? AppColors.green
                : AppColors.border;
    final active = hostTalking || meTalking;
    return AnimatedContainer(
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
        muted
            ? Icons.mic_off_rounded
            : hostTalking
                ? Icons.volume_up_rounded
                : Icons.mic_rounded,
        color: color == AppColors.border ? AppColors.textSecondary : color,
        size: 44,
      ),
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
        Icon(icon, color: AppColors.amber, size: 44),
        const SizedBox(height: 18),
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
