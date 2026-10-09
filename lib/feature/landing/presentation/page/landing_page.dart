import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/route_arrival.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../../../core/widget/settings_icon_button.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';
import '../widget/landing_identity_card.dart';
import '../widget/landing_logo.dart';
import '../widget/room_entry_options.dart';
import '../widget/room_rejoin_prompt.dart';

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
    with TickerProviderStateMixin, RouteArrival<LandingPage> {
  // Staggered entrance for all sections: [logo, card, actions, footer]
  late AnimationController _entranceController;
  late List<CurvedAnimation> _sections;
  final _stageKey = GlobalKey();
  final _logoSlotKey = GlobalKey();
  double _logoLift = 0;
  late final CurvedAnimation _logoReveal = CurvedAnimation(
    parent: _entranceController,
    curve: const Interval(0, 0.36, curve: AppMotion.easeOut),
  );
  late final CurvedAnimation _logoDock = CurvedAnimation(
    parent: _entranceController,
    curve: const Interval(0.32, 0.64, curve: AppMotion.easeInOut),
  );

  @override
  void initState() {
    super.initState();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    );

    const starts = [0.0, 0.60, 0.72, 0.84];
    const ends = [0.22, 0.80, 0.94, 1.0];
    _sections = List.generate(
      4,
      (i) => CurvedAnimation(
        parent: _entranceController,
        curve: Interval(starts[i], ends[i], curve: AppMotion.easeOut),
      ),
    );
  }

  @override
  void onRouteArrived() => unawaited(_introduceHome());

  Future<void> _introduceHome() async {
    final stage = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    final slot = _logoSlotKey.currentContext?.findRenderObject() as RenderBox?;
    if (stage != null && slot != null) {
      _logoLift =
          stage.localToGlobal(stage.size.center(Offset.zero)).dy -
          slot.localToGlobal(slot.size.center(Offset.zero)).dy;
    }
    try {
      if (AppMotion.reduced(context)) {
        _entranceController.value = 1;
      } else {
        await _entranceController.forward().orCancel;
      }
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        await RoomRejoinPrompt.maybeAsk(context);
      }
    } on TickerCanceled {
      // Leaving Home retires the remaining entrance and its optional prompt.
    }
  }

  @override
  void dispose() {
    _logoReveal.dispose();
    _logoDock.dispose();
    for (final section in _sections) {
      section.dispose();
    }
    _entranceController.dispose();
    super.dispose();
  }

  Widget _entrance(int index, Widget child) => AnimatedBuilder(
    animation: _sections[index],
    child: child,
    builder: (_, prebuilt) => IgnorePointer(
      ignoring: _sections[index].value < 0.2,
      child: ExcludeSemantics(
        excluding: _sections[index].value < 0.2,
        child: Opacity(
          opacity: _sections[index].value,
          child: Transform.translate(
            offset: Offset(
              0,
              AppMotion.reduced(context)
                  ? 0
                  : 24 * (1 - _sections[index].value),
            ),
            child: prebuilt,
          ),
        ),
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
                  key: _stageKey,
                  children: [
                    CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          sliver: SliverFillRemaining(
                            hasScrollBody: false,
                            child: Column(
                              children: [
                                const Spacer(flex: 2),
                                SizedBox(
                                  key: _logoSlotKey,
                                  child: _entrance(
                                    0,
                                    AnimatedBuilder(
                                      animation: _logoDock,
                                      child: LandingLogo(reveal: _logoReveal),
                                      builder: (_, logo) => Transform.translate(
                                        offset: Offset(
                                          0,
                                          AppMotion.reduced(context)
                                              ? 0
                                              : _logoLift *
                                                    (1 - _logoDock.value),
                                        ),
                                        child: Transform.scale(
                                          scale: AppMotion.reduced(context)
                                              ? 1
                                              : 1.08 - 0.08 * _logoDock.value,
                                          child: logo,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const Spacer(flex: 2),
                                _entrance(
                                  1,
                                  Column(
                                    children: [
                                      LandingIdentityCard(
                                        state: state,
                                        onEdit: () => context.pushNamed(
                                          AppRoutes.profileName,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      _TransportChip(pinned: state.pinnedMode),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),
                                _entrance(2, const RoomEntryOptions()),
                                const Spacer(flex: 1),
                                _entrance(
                                  3,
                                  VersionBadge(
                                    color: AppColors.textSecondary.withAlpha(
                                      70,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    PositionedDirectional(
                      top: 8,
                      end: 12,
                      child: _entrance(
                        3,
                        SettingsIconButton(
                          onTap: () =>
                              context.pushNamed(AppRoutes.settingsName),
                        ),
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
}

// ── Transport chip ───────────────────────────────────────────────────────────

/// Names the selected transport and opens the place to change it.
class _TransportChip extends StatelessWidget {
  final TransferMode? pinned;

  const _TransportChip({required this.pinned});

  String _label(AppLocalizations s, TransferMode? mode) => switch (mode) {
    null ||
    TransferMode.wifi ||
    TransferMode.hotspot => s.transport_wifi_hotspot,
    TransferMode.bluetooth => s.transport_bluetooth,
    TransferMode.guest => s.transport_guest,
  };

  IconData _icon(TransferMode? mode) => switch (mode) {
    null || TransferMode.wifi || TransferMode.hotspot => Icons.wifi_rounded,
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
            Flexible(
              child: Text(
                _label(s, pinned),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
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
