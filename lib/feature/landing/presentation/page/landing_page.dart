import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/paywall_sheet.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../../../core/widget/settings_icon_button.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../preflight/presentation/page/preflight_page.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';
import '../widget/landing_identity_card.dart';
import '../widget/landing_logo.dart';
import '../widget/channel_actions.dart';

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
  // Staggered entrance for all sections: [logo, card, actions, footer]
  late AnimationController _entranceController;
  late List<Animation<double>> _sections;

  // pulse animation used by the primary channel action only
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
          builder: (context, state) => Stack(
            children: [
              // Full-bleed animated mesh behind everything, including the
              // status-bar area — hence outside the SafeArea.
              const Positioned.fill(child: MeshBackground()),
              SafeArea(
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
                                _TransportChip(pinned: state.pinnedMode),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          _entrance(2, _buildChannelActions(context, state)),
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
                      top: 8,
                      end: 12,
                      child: SettingsIconButton(
                        onTap: () => context.pushNamed(AppRoutes.settingsName),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Channel actions ────────────────────────────────────────────────────────────

  Widget _buildChannelActions(BuildContext context, LandingState state) {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, _) => ChannelActions(
        createPlan: state.planFor(ChannelIntent.create),
        joinPlan: state.planFor(ChannelIntent.join),
        pulse: _pulseAnimation.value,
        // The local address is still being read. Every plan turns on it, so
        // acting now would commit to a transport chosen from a fact we have
        // not finished establishing.
        enabled: !state.isLoading,
        onTap: (plan) => _enterChannel(context, plan),
        onDifferentNetwork: () => _openHotspotBridge(context),
        onSameWifi: () => context.read<LandingCubit>().preferSharedNetwork(),
        hasWifi: state.hasWifiAddress,
      ),
    );
  }

  /// Commits to the plan's transport and walks it.
  ///
  /// The entitlement check comes first and opens the paywall rather than
  /// silently routing somewhere cheaper. Under automatic the advisor would
  /// happily hand back Bluetooth for a user whose Wi-Fi entitlement has
  /// lapsed, and that reads as the app quietly getting worse; a lock the user
  /// can act on does not. (Monetization is parked, so today the gate always
  /// allows and this is a no-op — it is here so that un-parking it does not
  /// have to find this call site.)
  Future<void> _enterChannel(BuildContext context, ChannelPlan plan) async {
    if (plan.mode.requiresPremium &&
        !GetIt.instance<LicenseGate>().allows(PremiumFeature.wifiTransport)) {
      showPaywallSheet(context, PremiumFeature.wifiTransport);
      return;
    }
    // Preflight (#33): the actual "before the phone goes in a pocket" moment
    // for every returning user — onboarding's own launch only ever fires
    // once, on a fresh install. Runs before anything below is committed, so
    // cancelling leaves Landing exactly as it was.
    final proceed = await showPreflightPage(context, plan: plan);
    if (!proceed || !context.mounted) return;

    final cubit = context.read<LandingCubit>();
    // Before the transport is committed and before we navigate: the channel
    // has to be settled by the time anything can put a packet on the wire.
    cubit.takeChannel(plan.intent);
    await cubit.markLaunched();
    // Written before navigating, not after: the page we are about to open
    // resolves its repository from the stored mode.
    await cubit.commit(plan.mode);
    if (!context.mounted) return;
    switch (plan.mode) {
      case TransferMode.wifi:
        // Nothing to set up — both phones are already on one network, so the
        // channel is the destination rather than a step past a setup screen.
        context.goNamed(AppRoutes.walkieName);
      case TransferMode.hotspot:
        context.pushNamed(
          AppRoutes.wifiHotspotName,
          queryParameters: {
            'mode': 'hotspot',
            // Carries the side the user already chose, so the bridge does not
            // re-ask "are you the host?" one screen after they answered it.
            'intent': plan.intent.key,
          },
        );
      case TransferMode.bluetooth:
        context.pushNamed(
          AppRoutes.bluetoothConnectName,
          queryParameters: {'intent': plan.intent.key},
        );
      case TransferMode.guest:
        context.pushNamed(AppRoutes.guestLinkName);
    }
  }

  /// "Not on the same network?" — the hotspot bridge with no side chosen.
  ///
  /// Deliberately lands on the host/join picker rather than assuming: the user
  /// is telling us our reading of the situation was wrong, which is the worst
  /// possible moment to guess again.
  Future<void> _openHotspotBridge(BuildContext context) async {
    if (!GetIt.instance<LicenseGate>().allows(PremiumFeature.wifiTransport)) {
      showPaywallSheet(context, PremiumFeature.wifiTransport);
      return;
    }
    final cubit = context.read<LandingCubit>();
    await cubit.markLaunched();
    await cubit.commit(TransferMode.hotspot);
    if (!context.mounted) return;
    context.pushNamed(
      AppRoutes.wifiHotspotName,
      queryParameters: const {'mode': 'hotspot'},
    );
  }
}

// ── Transport chip ───────────────────────────────────────────────────────────

/// Says how the transport is being chosen, and opens the place to change it.
///
/// It reads "AUTOMATIC" for almost everyone, which is the point: the picker it
/// used to shortcut to has moved to Advanced settings, and this line is what
/// keeps that from feeling like the choice was taken away. When a transport
/// *has* been pinned it names it and marks it as hand-picked — a pin that
/// stops suiting the phone's situation is otherwise indistinguishable from the
/// app choosing badly, and the difference decides whether the user changes a
/// setting or files a bug.
class _TransportChip extends StatelessWidget {
  final TransferMode? pinned;

  const _TransportChip({required this.pinned});

  String _label(AppLocalizations s, TransferMode? mode) => switch (mode) {
    null => s.transport_automatic,
    TransferMode.wifi || TransferMode.hotspot => s.transport_wifi_hotspot,
    TransferMode.bluetooth => s.transport_bluetooth,
    TransferMode.guest => s.transport_guest,
  };

  IconData _icon(TransferMode? mode) => switch (mode) {
    null => Icons.auto_awesome_rounded,
    TransferMode.wifi || TransferMode.hotspot => Icons.wifi_rounded,
    TransferMode.bluetooth => Icons.bluetooth_rounded,
    TransferMode.guest => Icons.qr_code_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return GestureDetector(
      onTap: () => context.pushNamed(AppRoutes.advancedSettingsName),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(pinned), size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              _label(s, pinned),
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            if (pinned != null) ...[
              const SizedBox(width: 6),
              Text(
                s.channel_pinned_note,
                style: TextStyle(
                  color: AppColors.textSecondary.withAlpha(150),
                  fontSize: 10,
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 14,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
