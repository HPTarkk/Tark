import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/guest_link_state.dart';
import '../manager/guest_link_cubit.dart';

/// Host flow for inviting a browser guest: show the invite QR (scanned by
/// the guest's camera app → opens the join page), then scan the reply QR
/// off the guest's screen. Two scans, zero servers.
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
            context.pop();
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
                onRetry: () =>
                    context.read<GuestLinkCubit>().createInvite(),
              );
            }
            if (state.inviteUrl.isEmpty) {
              return Center(
                child: CircularProgressIndicator(color: AppColors.amber),
              );
            }
            return _InviteBody(
              inviteUrl: state.inviteUrl,
              onScanAnswer: () => _openScanner(context),
            );
          },
        ),
      ),
    );
  }
}

class _InviteBody extends StatelessWidget {
  final String inviteUrl;
  final VoidCallback onScanAnswer;

  const _InviteBody({required this.inviteUrl, required this.onScanAnswer});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppColors.amber.withAlpha(40),
                  blurRadius: 24,
                ),
              ],
            ),
            child: QrImageView(
              data: inviteUrl,
              version: QrVersions.auto,
              size: 250,
              gapless: true,
            ),
          ),
        ),
        const SizedBox(height: 24),
        _StepRow(index: '1', text: s.guest_step_scan),
        const SizedBox(height: 12),
        _StepRow(index: '2', text: s.guest_step_answer),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: onScanAnswer,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.amber.withAlpha(25),
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: AppColors.amber.withAlpha(130), width: 2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.qr_code_scanner_rounded,
                    color: AppColors.amber, size: 20),
                const SizedBox(width: 10),
                Text(
                  s.guest_scan_answer,
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

class _StepRow extends StatelessWidget {
  final String index;
  final String text;

  const _StepRow({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amber.withAlpha(28),
            border: Border.all(color: AppColors.amber.withAlpha(120)),
          ),
          child: Text(
            index,
            style: TextStyle(
              color: AppColors.amber,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// Fullscreen camera scanner for the guest's reply QR.
class _AnswerScanner extends StatefulWidget {
  const _AnswerScanner();

  @override
  State<_AnswerScanner> createState() => _AnswerScannerState();
}

class _AnswerScannerState extends State<_AnswerScanner> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
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
      body: Stack(
        children: [
          MobileScanner(
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
          // Aiming frame.
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(
                    color: AppColors.amber.withAlpha(200), width: 2),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
