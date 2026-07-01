import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../../feature/transfer/presentation/page/bluetooth_connect_page.dart';
import '../../../../feature/transfer/domain/entity/transfer_mode.dart';
import '../../../../feature/walkie/presentation/page/walkie_talkie_page.dart';
import '../manager/landing_cubit.dart';
import '../widget/landing_identity_card.dart';
import '../widget/landing_logo.dart';
import '../widget/language_toggle.dart';
import '../widget/transport_mode_toggle.dart';

class LandingPage extends StatefulWidget {
  static const path = '/';
  static const name = 'LandingPage';

  const LandingPage._();

  static Widget buildPage() => BlocProvider<LandingCubit>(
        create: (_) => LandingCubit(),
        child: const LandingPage._(),
      );

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage>
    with TickerProviderStateMixin {
  // Staggered entrance for all sections: [logo, card, btn, lang, footer]
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

    const starts = [0.0, 0.18, 0.34, 0.50, 0.65];
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
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: BlocBuilder<LandingCubit, LandingState>(
          builder: (context, state) => SafeArea(
            child: Padding(
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
                              _showEditNameDialog(context, state.myName),
                        ),
                        const SizedBox(height: 12),
                        const TransportModeToggle(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _entrance(2, _buildJoinButton(context, state)),
                  const SizedBox(height: 20),
                  _entrance(3, const LanguageToggle()),
                  const Spacer(flex: 1),
                  _entrance(
                    4,
                    VersionBadge(
                      color: AppColors.textSecondary.withAlpha(70),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
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
            ? () => context.pushNamed(
                  state.transferMode == TransferMode.bluetooth
                      ? BluetoothConnectPage.name
                      : WalkieTalkiePage.name,
                )
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

  // ── Edit name dialog ────────────────────────────────────────────────────────
  void _showEditNameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    final cubit = context.read<LandingCubit>();
    final s = context.getString;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Text(
          s.set_name_title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle:
                TextStyle(color: AppColors.textSecondary.withAlpha(160)),
            counterStyle:
                TextStyle(color: AppColors.textSecondary.withAlpha(120)),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.amber),
            ),
          ),
          onSubmitted: (v) {
            cubit.setMyName(v);
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              s.cancel,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              cubit.setMyName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: Text(
              s.save,
              style: const TextStyle(
                color: AppColors.amber,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
