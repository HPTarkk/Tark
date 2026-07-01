import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/ticker_text.dart';
import '../manager/walkie_talkie_cubit.dart';

class WalkieHeader extends StatelessWidget {
  const WalkieHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isReady != c.isReady || p.localId != c.localId,
      builder: (context, state) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            bottom: BorderSide(color: AppColors.border, width: 1),
          ),
        ),
        child: Row(
          children: [
            const _RadioIcon(),
            const SizedBox(width: 10),
            Text(
              context.getString.app_name,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
            const Spacer(),
            // RepaintBoundary isolates the 60 fps pulse dot from the header.
            const RepaintBoundary(child: SignalIndicator()),
          ],
        ),
      ),
    );
  }
}

// ── Radio icon ────────────────────────────────────────────────────────────────

class _RadioIcon extends StatelessWidget {
  const _RadioIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: AppColors.amber.withAlpha(30),
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.amber.withAlpha(80), width: 1),
      ),
      child: Icon(Icons.radio, color: AppColors.amber, size: 14),
    );
  }
}

// ── Signal indicator ──────────────────────────────────────────────────────────

/// Pulsing LIVE / OFFLINE indicator in the header.
///
/// Owns its own [AnimationController] so the pulse animation is isolated from
/// the rest of the page widget tree.
class SignalIndicator extends StatefulWidget {
  const SignalIndicator({super.key});

  @override
  State<SignalIndicator> createState() => _SignalIndicatorState();
}

class _SignalIndicatorState extends State<SignalIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isReady != c.isReady || p.localId != c.localId,
      builder: (context, state) {
        final isActive = state.isReady &&
            state.localId.isNotEmpty &&
            state.localId != '0.0.0.0';
        final s = context.getString;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, _) => Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive
                      ? Color.lerp(
                          AppColors.green,
                          AppColors.green.withAlpha(100),
                          _pulseAnimation.value,
                        )!
                      : AppColors.textSecondary,
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: AppColors.green.withAlpha(150),
                            blurRadius: 8 * _pulseAnimation.value,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 6),
            TickerText(
              text: isActive ? s.live : s.offline,
              duration: const Duration(milliseconds: 350),
              style: TextStyle(
                color: isActive ? AppColors.green : AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
          ],
        );
      },
    );
  }
}
