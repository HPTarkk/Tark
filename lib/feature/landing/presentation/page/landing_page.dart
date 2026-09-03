import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../../../core/widget/settings_icon_button.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../room/domain/entity/room.dart';
import '../../../room/domain/repository/room_repository.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';
import '../widget/landing_identity_card.dart';
import '../widget/landing_logo.dart';
import '../widget/room_entry_actions.dart';

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

  @override
  void initState() {
    super.initState();

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
                          _entrance(2, _RoomEntryActions()),
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
}

/// The Room is created before a transport is selected. A Room therefore has a
/// single, obvious home-screen entry instead of being hidden behind Channel.
///
/// What that entry *says* depends on whether this phone has a Room already.
/// With one saved, the lead action resumes it and the list is one tap away;
/// without one, creating leads. Previously the only route to the saved list
/// ran through the create action, so returning to yesterday's Room meant
/// opening the create dialog and dismissing it.
class _RoomEntryActions extends StatefulWidget {
  @override
  State<_RoomEntryActions> createState() => _RoomEntryActionsState();
}

class _RoomEntryActionsState extends State<_RoomEntryActions> {
  List<SavedRoom> _rooms = const [];
  SavedRoom? _selected;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Landing stays on the stack under the room list, so coming back has to
    // re-read: a Room created or left over there changes which action leads.
    if (_loaded) unawaited(_load());
  }

  Future<void> _load() async {
    if (!GetIt.instance.isRegistered<RoomRepository>()) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    try {
      final repository = GetIt.instance<RoomRepository>();
      final rooms = await repository.list();
      final selectedId = await repository.selectedRoomId();
      if (!mounted) return;
      SavedRoom? selected;
      for (final saved in rooms) {
        if (saved.room.id == selectedId) {
          selected = saved;
          break;
        }
      }
      setState(() {
        _rooms = rooms;
        _selected = selected;
        _loaded = true;
      });
    } catch (_) {
      // Landing must open with or without Room storage. Falling through to
      // the first-run shape is honest: it offers create and join, both of
      // which work, rather than claiming a Room we could not read.
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final resume = _selected ?? (_rooms.isEmpty ? null : _rooms.first);

    // First run has genuinely two options and no list to browse, so it keeps
    // the full-width pair of rows: a screen with two things on it is not a
    // list, and narrowing them into halves would only make them harder to hit
    // for no gain. Every later run has three, which is where the tiers matter.
    if (resume == null) {
      return RoomEntryActions(
        hero: RoomEntryAction(
          key: const Key('landing-create-room'),
          icon: Icons.add_home_work_outlined,
          label: fa ? 'ساخت اتاق' : 'CREATE ROOM',
          hint: fa
              ? 'یک اتاق بساز و بقیه را دعوت کن'
              : 'Start one and invite the others',
          variant: RoomEntryVariant.hero,
          onTap: () => context.push('${AppRoutes.roomsPath}?create=true'),
        ),
        alternatives: [
          RoomEntryAction(
            key: const Key('landing-join-room'),
            icon: Icons.qr_code_scanner_rounded,
            label: fa ? 'پیوستن با QR' : 'JOIN WITH QR',
            hint: fa
                ? 'کد روی گوشی میزبان را اسکن کن'
                : "Scan the code on the host's phone",
            variant: RoomEntryVariant.wide,
            onTap: () => context.push(AppRoutes.roomQrJoinPath),
          ),
        ],
      );
    }

    return RoomEntryActions(
      // The room's own mark rather than a door glyph: this is the card the
      // user picked it on, one screen earlier.
      hero: RoomEntryAction(
        key: const Key('landing-resume-room'),
        icon: Icons.meeting_room_rounded,
        monogram: resume.room.name,
        label: resume.room.name,
        hint: fa ? 'ادامه در این اتاق' : 'Pick up where you left off',
        variant: RoomEntryVariant.hero,
        onTap: () => context.push(AppRoutes.walkiePath),
      ),
      // Side by side because they are alternatives to *each other* — both are
      // "begin something new". Saying that is what finally gets create out of
      // MY ROOMS' hint text, and it costs no height to say.
      alternatives: [
        RoomEntryAction(
          key: const Key('landing-join-room'),
          icon: Icons.qr_code_scanner_rounded,
          label: fa ? 'پیوستن' : 'JOIN',
          hint: fa ? 'کد میزبان را اسکن کن' : "Scan a host's code",
          variant: RoomEntryVariant.compact,
          onTap: () => context.push(AppRoutes.roomQrJoinPath),
        ),
        RoomEntryAction(
          key: const Key('landing-create-room'),
          // Not a bare `add_rounded`: a thin cross beside the QR glyph's dense
          // frame makes one half of the pair look lighter than the other, which
          // is the one thing this row must not say.
          icon: Icons.add_circle_outline_rounded,
          label: fa ? 'اتاق تازه' : 'NEW ROOM',
          hint: fa ? 'خودت یکی بساز' : 'Start your own',
          variant: RoomEntryVariant.compact,
          onTap: () => context.push('${AppRoutes.roomsPath}?create=true'),
        ),
      ],
      browse: RoomBrowseLink(
        key: const Key('landing-all-rooms'),
        label: fa ? 'اتاق‌های من' : 'MY ROOMS',
        count: _rooms.length.localized(context),
        onTap: () => context.push(AppRoutes.roomsPath),
      ),
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
