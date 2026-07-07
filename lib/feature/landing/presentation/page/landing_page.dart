import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';
import '../widget/landing_identity_card.dart';
import '../widget/landing_logo.dart';
import '../widget/transport_mode_toggle.dart';

class LandingPage extends StatefulWidget {
  const LandingPage._();

  static Widget buildPage() => BlocProvider<LandingCubit>(
        create: (_) => GetIt.instance<LandingCubit>(),
        child: const LandingPage._(),
      );

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage>
    with TickerProviderStateMixin {
  // Staggered entrance for all sections: [logo, card, btn, footer]
  late AnimationController _entranceController;
  late List<Animation<double>> _sections;

  // pulse animation used by the join button only
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    const starts = [0.0, 0.22, 0.44, 0.66];
    _sections = starts
        .map(
          (s) => CurvedAnimation(
            parent: _entranceController,
            curve: Interval(
              s,
              (s + 0.40).clamp(0.0, 1.0),
              curve: Curves.easeOutCubic,
            ),
          ),
        )
        .toList();

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _entranceController.forward(),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  Widget _entrance(int index, Widget child) => AnimatedBuilder(
        animation: _sections[index],
        child: child,
        builder: (_, prebuilt) => Opacity(
          opacity: _sections[index].value,
          child: Transform.translate(
            offset: Offset(0, 28 * (1 - _sections[index].value)),
            child: prebuilt,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: BlocBuilder<LandingCubit, LandingState>(
          builder: (context, state) => SafeArea(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const Spacer(flex: 2),
                      _entrance(0, const LandingLogo()),
                      const Spacer(flex: 2),
                      _entrance(
                        1,
                        Column(
                          children: [
                            LandingIdentityCard(
                              state: state,
                              onEdit: () =>
                                  context.pushNamed(AppRoutes.settingsName),
                            ),
                            const SizedBox(height: 12),
                            const TransportModeToggle(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      _entrance(2, _buildJoinButton(context, state)),
                      const Spacer(flex: 1),
                      _entrance(
                        3,
                        VersionBadge(
                          color: AppColors.textSecondary.withAlpha(70),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                PositionedDirectional(
                  top: 4,
                  end: 4,
                  child: _SettingsButton(onTap: () {
                    HapticFeedback.selectionClick();
                    context.pushNamed(AppRoutes.settingsName);
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Join Button ─────────────────────────────────────────────────────────────
  Widget _buildJoinButton(BuildContext context, LandingState state) {
    final enabled = state.hasNetwork && !state.isLoading;
    return AnimatedBuilder(
      animation: _pulseAnimation,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.podcasts_rounded,
            color: state.hasNetwork ? AppColors.amber : AppColors.textSecondary,
            size: 22,
          ),
          const SizedBox(width: 12),
          Text(
            context.getString.join_channel,
            style: TextStyle(
              color:
                  state.hasNetwork ? AppColors.amber : AppColors.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
      builder: (_, child) => GestureDetector(
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                context.read<LandingCubit>().markLaunched();
                context.pushNamed(switch (state.transferMode) {
                  TransferMode.bluetooth => AppRoutes.bluetoothConnectName,
                  TransferMode.hotspot => AppRoutes.hotspotBridgeName,
                  TransferMode.guest => AppRoutes.guestLinkName,
                  TransferMode.wifi => AppRoutes.walkieName,
                });
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.amber.withAlpha(25)
                : AppColors.border.withAlpha(40),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: enabled
                  ? Color.lerp(
                      AppColors.amber,
                      AppColors.amber.withAlpha(120),
                      _pulseAnimation.value,
                    )!
                  : AppColors.border,
              width: 2,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.amber.withAlpha(
                        (15 + 40 * _pulseAnimation.value).toInt(),
                      ),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: child!,
        ),
      ),
    );
  }

}

// ── Settings entry point ──────────────────────────────────────────────────────

class _SettingsButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SettingsButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.settings_rounded,
          color: AppColors.textSecondary,
          size: 22,
        ),
      ),
    );
  }
}
