import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../domain/entity/guest_link_state.dart';
import '../manager/guest_link_cubit.dart';

/// Host flow for inviting a browser guest: show the invite QR/link, then
/// either scan the reply QR off the guest's screen or paste the reply code
/// they send back — the second path is what makes a genuinely remote guest
/// (not in the same room) reachable, now that the transport also carries
/// public STUN (see ice_config.dart). Zero servers either way.
class GuestLinkPage extends StatefulWidget {
  const GuestLinkPage._();

  static Widget buildPage() => BlocProvider<GuestLinkCubit>(
        create: (_) => GetIt.instance<GuestLinkCubit>(),
        child: const GuestLinkPage._(),
      );

  @override
  State<GuestLinkPage> createState() => _GuestLinkPageState();
}

class _GuestLinkPageState extends State<GuestLinkPage> {
  bool _navigating = false;

  Future<void> _openScanner(BuildContext context) async {
    final cubit = context.read<GuestLinkCubit>();
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _AnswerScanner()),
    );
    if (scanned != null && scanned.isNotEmpty) {
      await cubit.submitAnswer(scanned);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () {
            context.read<GuestLinkCubit>().cancel();
            if (context.canPop()) {
              context.pop();
            } else {
              // Reached directly (quick access landed here) — no stack to
              // pop to.
              context.goNamed(AppRoutes.landingName);
            }
          },
        ),
        title: Text(
          s.guest_invite_title,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<GuestLinkCubit, GuestLinkPageState>(
          listener: (context, state) async {
            if (state.link == GuestLinkState.connected && !_navigating) {
              setState(() => _navigating = true);
              await Future<void>.delayed(const Duration(milliseconds: 900));
              if (context.mounted) context.goNamed(AppRoutes.walkieName);
            }
          },
          builder: (context, state) {
            if (state.link == GuestLinkState.connected || _navigating) {
              return const _SuccessFlash();
            }
            if (state.link == GuestLinkState.failed) {
              return _ErrorRetry(
                onRetry: () => context.read<GuestLinkCubit>().createInvite(),
              );
            }
            if (state.inviteUrl.isEmpty) {
              return const _PreparingLink();
            }
            return _InviteBody(
              inviteUrl: state.inviteUrl,
              onScanAnswer: () => _openScanner(context),
              onSubmitAnswer: (text) =>
                  context.read<GuestLinkCubit>().submitAnswer(text),
            );
          },
        ),
      ),
    );
  }
}

// ── Preparing ───────────────────────────────────────────────────────────────

class _PreparingLink extends StatelessWidget {
  const _PreparingLink();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              color: AppColors.amber,
              strokeWidth: 2.5,
            ),
          ),
          const SizedBox(height: 18),
          _LanBadge(),
        ],
      ),
    );
  }
}

// ── Invite (QR + steps) ─────────────────────────────────────────────────────

class _InviteBody extends StatelessWidget {
  final String inviteUrl;
  final VoidCallback onScanAnswer;
  final ValueChanged<String> onSubmitAnswer;

  const _InviteBody({
    required this.inviteUrl,
    required this.onScanAnswer,
    required this.onSubmitAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _Entrance(delayMs: 0, child: Center(child: _LanBadge())),
        const SizedBox(height: 18),
        _Entrance(
          delayMs: 80,
          child: Center(child: GlowingQrCard(data: inviteUrl, size: 236)),
        ),
        const SizedBox(height: 12),
        _Entrance(
          delayMs: 120,
          child: Center(child: _CopyChip(text: inviteUrl, label: s.guest_copy_link, copiedLabel: s.guest_link_copied)),
        ),
        const SizedBox(height: 22),
        _Entrance(
          delayMs: 160,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                StepRow(
                  index: 1,
                  icon: Icons.photo_camera_rounded,
                  text: s.guest_step_scan,
                ),
                const SizedBox(height: 12),
                Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 12),
                StepRow(
                  index: 2,
                  icon: Icons.qr_code_scanner_rounded,
                  text: s.guest_step_answer,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _Entrance(
          delayMs: 240,
          child: _PulsingActionButton(
            icon: Icons.qr_code_scanner_rounded,
            label: s.guest_scan_answer,
            onTap: onScanAnswer,
          ),
        ),
        const SizedBox(height: 16),
        _Entrance(
          delayMs: 280,
          child: Center(
            child: GestureDetector(
              onTap: () => _showPasteAnswerDialog(context, onSubmitAnswer),
              child: Text(
                s.guest_paste_answer,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.textSecondary.withAlpha(140),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _Entrance(
          delayMs: 320,
          child: Text(
            s.guest_stun_caveat,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary.withAlpha(150),
              fontSize: 10.5,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

void _showPasteAnswerDialog(
  BuildContext context,
  ValueChanged<String> onSubmit,
) {
  final controller = TextEditingController();
  final s = context.getString;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.border),
      ),
      title: Text(
        s.guest_paste_answer,
        style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        style: TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: s.guest_paste_answer_hint,
          hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(160)),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.amber),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(s.cancel, style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            onSubmit(controller.text);
            Navigator.of(ctx).pop();
          },
          child: Text(
            s.guest_paste_submit,
            style: TextStyle(color: AppColors.amber, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

/// "NO SERVER" — the whole point, worn as a badge. (No longer claims
/// LAN-only: public STUN, see ice_config.dart, also reaches remote guests.)
class _LanBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.green.withAlpha(16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.green.withAlpha(110)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_tethering_rounded,
              color: AppColors.green, size: 13),
          const SizedBox(width: 6),
          Text(
            context.getString.guest_no_server_badge,
            style: TextStyle(
              color: AppColors.green,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small tap-to-copy chip, reused for the invite link.
class _CopyChip extends StatelessWidget {
  final String text;
  final String label;
  final String copiedLabel;

  const _CopyChip({required this.text, required this.label, required this.copiedLabel});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(copiedLabel),
            duration: const Duration(seconds: 1),
            backgroundColor: AppColors.card,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy_rounded, color: AppColors.amber, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Primary action with a slow breathing glow so it reads as "this is your
/// next move" without shouting.
class _PulsingActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PulsingActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_PulsingActionButton> createState() => _PulsingActionButtonState();
}

class _PulsingActionButtonState extends State<_PulsingActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The glow is a static pre-blurred layer whose OPACITY breathes —
    // compositor-only work. Animating BoxShadow blur directly re-blurs
    // every frame and janks low-end phones.
    return Stack(
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: Tween<double>(begin: 0.25, end: 1.0).animate(
              CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
            ),
            child: RepaintBoundary(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.amber.withAlpha(60),
                      blurRadius: 24,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.amber.withAlpha(25),
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: AppColors.amber.withAlpha(140), width: 2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, color: AppColors.amber, size: 20),
                const SizedBox(width: 10),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: AppColors.amber,
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
  }
}

// ── Scanner ─────────────────────────────────────────────────────────────────

/// Fullscreen viewfinder for the guest's reply QR: dark scrim with a clear
/// window, corner brackets, a running scan line, and a torch toggle.
class _AnswerScanner extends StatefulWidget {
  const _AnswerScanner();

  @override
  State<_AnswerScanner> createState() => _AnswerScannerState();
}

class _AnswerScannerState extends State<_AnswerScanner>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController();
  late final AnimationController _line = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);

  bool _done = false;
  bool _torchOn = false;

  @override
  void dispose() {
    _line.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    const window = 260.0;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          s.guest_scan_answer,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final windowRect = Rect.fromCenter(
            center: Offset(
              constraints.maxWidth / 2,
              constraints.maxHeight / 2 - 40,
            ),
            width: window,
            height: window,
          );
          return Stack(
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: (capture) {
                  if (_done) return;
                  for (final barcode in capture.barcodes) {
                    final value = barcode.rawValue;
                    if (value != null && value.isNotEmpty) {
                      _done = true;
                      Navigator.of(context).pop(value);
                      return;
                    }
                  }
                },
              ),
              // Scrim with a clear window.
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ScrimPainter(window: windowRect),
                  ),
                ),
              ),
              // Brackets + scan line inside the window.
              Positioned.fromRect(
                rect: windowRect.inflate(10),
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: CornerBracketsPainter(
                      color: AppColors.amber,
                      length: 32,
                      stroke: 3.5,
                    ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: windowRect,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _line,
                    builder: (context, child) {
                      final t = Curves.easeInOut.transform(_line.value);
                      return Align(
                        alignment: Alignment(0, t * 2 - 1),
                        child: child,
                      );
                    },
                    // Static pre-blurred strip moved by the compositor —
                    // re-blurring a glow every frame over a camera preview
                    // is exactly the kind of thing that janks.
                    child: RepaintBoundary(
                      child: Container(
                        height: 2.4,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppColors.amber.withAlpha(0),
                              AppColors.amber,
                              AppColors.amber.withAlpha(0),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.amber.withAlpha(140),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Hint + torch.
              Positioned(
                left: 24,
                right: 24,
                bottom: 42,
                child: Column(
                  children: [
                    Text(
                      s.guest_step_answer,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withAlpha(190),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    GestureDetector(
                      onTap: () async {
                        await _controller.toggleTorch();
                        if (mounted) setState(() => _torchOn = !_torchOn);
                      },
                      child: Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _torchOn
                              ? AppColors.amber.withAlpha(46)
                              : Colors.white.withAlpha(16),
                          border: Border.all(
                            color: _torchOn
                                ? AppColors.amber
                                : Colors.white.withAlpha(90),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          _torchOn
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          color: _torchOn ? AppColors.amber : Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ScrimPainter extends CustomPainter {
  final Rect window;

  _ScrimPainter({required this.window});

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()
        ..addRRect(RRect.fromRectAndRadius(window, const Radius.circular(18))),
    );
    canvas.drawPath(scrim, Paint()..color = Colors.black.withAlpha(150));
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.window != window;
}

// ── Success / error / entrance ──────────────────────────────────────────────

class _SuccessFlash extends StatelessWidget {
  const _SuccessFlash();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
              child:
                  Icon(Icons.check_rounded, color: AppColors.green, size: 42),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            s.bt_connected,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorRetry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: AppColors.red, size: 40),
            const SizedBox(height: 16),
            Text(
              s.guest_link_failed,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.amber.withAlpha(120), width: 1.5),
                ),
                child: Text(
                  s.retry,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small fade+slide entrance, matching the Bluetooth journey.
class _Entrance extends StatefulWidget {
  final Widget child;
  final int delayMs;

  const _Entrance({required this.child, required this.delayMs});

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final CurvedAnimation _anim =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _anim.value,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - _anim.value)),
          child: child,
        ),
      ),
    );
  }
}
