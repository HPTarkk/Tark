import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/route_arrival.dart';
import '../../../../core/router/route_exit.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/localized_counter.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';
import '../widget/room_formation.dart';
import '../widget/room_visuals.dart';
import '../../../../core/utils/localized_digits_formatter.dart';

class RoomCreatePage extends StatefulWidget {
  const RoomCreatePage({super.key, this.onCreated, this.onExit});

  /// Landing's create action renders this page on its first route frame.
  /// Creation from the saved-room list still uses the list's existing cubit
  /// and returns the result to that caller.
  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: Builder(
      builder: (context) => RoomCreatePage(
        onCreated: (_) => context.go(AppRoutes.walkiePath),
        onExit: () => exitRouteTo(context, AppRoutes.landingPath),
      ),
    ),
  );

  final ValueChanged<SavedRoom>? onCreated;
  final VoidCallback? onExit;
  @override
  State<RoomCreatePage> createState() => _RoomCreatePageState();
}

class _RoomCreatePageState extends State<RoomCreatePage>
    with TickerProviderStateMixin, RouteArrival<RoomCreatePage> {
  final _name = TextEditingController();
  late final _arrival = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );

  /// The lock-in sequence that plays once the Room exists (see
  /// [RoomFormation]). The whole page choreographs off this one value.
  late final _lockIn = AnimationController(
    vsync: this,
    duration: RoomFormation.lockInDuration,
  )..addListener(_lockInBeats);

  /// Completes when the page may hand over: the sequence ended, or the
  /// person tapped through it.
  Completer<void>? _handoff;
  bool _channelLocked = false, _checked = false;
  SavedRoom? _created;
  bool _busy = false, _ready = false;
  String? _error;
  bool get _premiumLocked {
    final state = context.watch<RoomListCubit>().state;
    return RoomAccessPolicy.additionalRoomRequiresPremium(state.rooms.length) &&
        GetIt.instance.isRegistered<LicenseGate>() &&
        !GetIt.instance<LicenseGate>().allows(PremiumFeature.extraRooms);
  }

  @override
  void onRouteArrived() {
    if (AppMotion.reduced(context)) {
      _arrival.value = 1;
    } else {
      _arrival.forward();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _arrival.dispose();
    _lockIn.dispose();
    super.dispose();
  }

  /// Haptics on the sequence's two physical beats: the channel locking
  /// (firm) and the check landing (light). Fired from the value itself, so a
  /// skip that jumps past a beat never fires it late.
  void _lockInBeats() {
    final value = _lockIn.value;
    if (!_channelLocked && value >= RoomFormation.lockBeat) {
      _channelLocked = true;
      if (_lockIn.isAnimating) HapticFeedback.mediumImpact();
      // The headline changes on the lock, not on the network reply.
      if (mounted) setState(() {});
    }
    if (!_checked && value >= RoomFormation.checkBeat) {
      _checked = true;
      if (_lockIn.isAnimating) HapticFeedback.lightImpact();
    }
  }

  /// Runs the lock-in and resolves when the page may hand over.
  Future<void> _playLockIn() {
    final handoff = _handoff = Completer<void>();
    if (AppMotion.reduced(context)) {
      // A calm, complete confirmation: the final frame, held for a beat.
      HapticFeedback.mediumImpact();
      _lockIn.value = 1;
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (!handoff.isCompleted) handoff.complete();
      });
    } else {
      HapticFeedback.selectionClick();
      _lockIn.forward(from: 0).whenCompleteOrCancel(() {
        if (!handoff.isCompleted) handoff.complete();
      });
    }
    return handoff.future;
  }

  /// Tapping anywhere, or the ready button, goes straight on.
  void _skip() {
    final handoff = _handoff;
    if (handoff == null || handoff.isCompleted) return;
    _lockIn
      ..stop()
      ..value = 1;
    handoff.complete();
  }

  Future<void> _create() async {
    if (_busy || _ready || _name.text.trim().isEmpty) return;
    final cubit = context.read<RoomListCubit>();
    if (cubit.state.loading) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      if (await cubit.needsMoreRoomsAccess()) {
        if (!mounted ||
            !await openSubscriptionGate(context, PremiumFeature.extraRooms)) {
          return;
        }
      }
      if (!mounted) return;
      var displayName = '';
      try {
        displayName = await GetIt.instance<SettingsRepository>().getMyName();
      } catch (_) {}
      if (!mounted) return;
      final created = await cubit.createRoom(
        name: _name.text.trim(),
        localDisplayName: displayName.trim().isEmpty
            ? context.getString.rooms_fallback_member_name
            : displayName.trim(),
      );
      if (!mounted) return;
      if (created == null) {
        setState(
          () => _error = cubit.state.error is RoomLimitReached
              ? context.getString.paywall_locked_rooms
              : context.getString.room_create_failed,
        );
        return;
      }
      setState(() {
        _ready = true;
        _created = created;
      });
      await _playLockIn();
      if (mounted) {
        if (widget.onCreated case final onCreated?) {
          onCreated(created);
        } else {
          Navigator.of(context).pop<SavedRoom>(created);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.getString.room_create_failed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _enter(int index, Widget child) => AnimatedBuilder(
    animation: _arrival,
    child: child,
    builder: (_, child) {
      final progress = Interval(
        index * 0.14,
        (0.58 + index * 0.14).clamp(0, 1),
        curve: AppMotion.easeOut,
      ).transform(_arrival.value);
      return IgnorePointer(
        ignoring: progress < 0.2,
        child: Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(
              0,
              AppMotion.reduced(context) ? 0 : 20 * (1 - progress),
            ),
            child: child,
          ),
        ),
      );
    },
  );

  /// The form steps back while the lock-in plays — fading and sinking a
  /// little, one row after another — so the emblem and the headline are the
  /// only things left moving. It keeps its space: nothing reflows.
  Widget _recede(int index, Widget child) => AnimatedBuilder(
    animation: _lockIn,
    child: child,
    builder: (context, child) {
      final ms = _lockIn.value * RoomFormation.lockInDuration.inMilliseconds;
      final from = 140 + index * 60;
      final progress = AppMotion.easeOut.transform(
        ((ms - from) / 360).clamp(0.0, 1.0),
      );
      if (progress == 0) return child!;
      return IgnorePointer(
        child: Opacity(
          opacity: 1 - progress,
          child: Transform.translate(
            offset: Offset(0, 14 * progress),
            child: child,
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final loadingRooms = context.watch<RoomListCubit>().state.loading;
    return PopScope(
      canPop: widget.onExit == null && !_busy && !_ready,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy && !_ready) widget.onExit?.call();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            const Positioned.fill(child: MeshBackground()),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 20, 0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: _busy || _ready
                              ? null
                              : widget.onExit ??
                                    () => Navigator.of(context).pop(),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          s.rooms_new_room,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                      children: [
                        _enter(
                          0,
                          RoomFormation(
                            assembling: _busy && !_ready,
                            lockIn: _ready ? _lockIn : null,
                            emblem: _created?.room.name ?? '',
                          ),
                        ),
                        _enter(
                          1,
                          AnimatedSwitcher(
                            duration: AppMotion.entrance,
                            // The old line clears quickly so the two never
                            // sit legibly on top of each other.
                            reverseDuration: AppMotion.chip,
                            switchInCurve: AppMotion.easeOut,
                            switchOutCurve: AppMotion.leaving,
                            // The new headline rises in on the lock as the
                            // old one sinks away: one motion, not a blink.
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween(
                                      begin: const Offset(0, 0.35),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: ScaleTransition(
                                      scale: Tween<double>(
                                        begin: 0.92,
                                        end: 1,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                                ),
                            child: Text(
                              _channelLocked
                                  ? s.room_create_ready
                                  : s.room_create_title,
                              key: ValueKey(_channelLocked),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 30,
                                height: 1.25,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _enter(
                          1,
                          Stack(
                            alignment: Alignment.topCenter,
                            children: [
                              _recede(
                                0,
                                Text(
                                  s.room_create_hint,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                    height: 1.65,
                                  ),
                                ),
                              ),
                              if (_created case final created?)
                                _ChannelTag(
                                  name: created.room.name,
                                  lockIn: _lockIn,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 30),
                        _enter(
                          2,
                          _recede(
                            1,
                            TextField(
                              key: const Key('room-name-field'),
                              controller: _name,
                              enabled: !_busy && !_ready,
                              maxLength: 48,
                              buildCounter: localizedCounter(),
                              // Digits typed in the name read in the app's
                              // language: «سفر ۲», never «سفر 2».
                              inputFormatters: [
                                LocaleDigitsFormatter.of(context),
                              ],
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => unawaited(_create()),
                              onChanged: (_) => setState(() => _error = null),
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                              decoration: InputDecoration(
                                labelText: s.rooms_name_hint,
                                hintText: s.room_create_name_example,
                                filled: true,
                                fillColor: AppColors.card,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 20,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide(
                                    color: AppColors.border,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide(
                                    color: AppColors.amber,
                                    width: 1.5,
                                  ),
                                ),
                                errorText: _error,
                              ),
                            ),
                          ),
                        ),
                        _enter(
                          3,
                          _recede(
                            2,
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _premiumLocked
                                      ? Icons.workspace_premium_rounded
                                      : Icons.lock_outline_rounded,
                                  size: 16,
                                  color: AppColors.textSecondary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _premiumLocked
                                        ? s.room_create_limit_hint
                                        : s.room_create_private_hint,
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                      height: 1.6,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _enter(
                    3,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                      child: AnimatedOpacity(
                        opacity: _name.text.trim().isEmpty ? 0.45 : 1,
                        duration: AppMotion.card,
                        child: RoomConnectButton(
                          key: const Key('room-name-submit'),
                          compact: true,
                          label: _ready
                              ? s.room_create_ready
                              : _busy
                              ? s.room_create_working
                              : _premiumLocked
                              ? s.lobby_unlock_premium
                              : s.rooms_create,
                          busy: _busy && !_ready,
                          icon: _ready
                              ? Icons.check_rounded
                              : _premiumLocked
                              ? Icons.workspace_premium_rounded
                              : Icons.add_rounded,
                          onTap: _ready
                              ? _skip
                              : _busy ||
                                    loadingRooms ||
                                    _name.text.trim().isEmpty
                              ? null
                              : () => unawaited(_create()),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // While the lock-in plays, a tap anywhere goes straight on: the
            // celebration never stands between someone and their Room.
            if (_ready)
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('room-create-skip'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _skip,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The new Room's name, tuned in: a small channel tag that springs up under
/// the headline once the channel locks.
class _ChannelTag extends StatelessWidget {
  const _ChannelTag({required this.name, required this.lockIn});

  final String name;
  final Animation<double> lockIn;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final tag = Container(
      key: const Key('room-create-channel-tag'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: amber.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cell_tower_rounded, size: 16, color: amber),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    return AnimatedBuilder(
      animation: lockIn,
      child: tag,
      builder: (context, child) {
        final ms = lockIn.value * RoomFormation.lockInDuration.inMilliseconds;
        final t = ((ms - 420) / 480).clamp(0.0, 1.0);
        if (t == 0) return const SizedBox.shrink();
        // Rises on a soft spring: a touch past its place, then settles.
        final rise = Curves.easeOutBack.transform(t);
        return Opacity(
          opacity: Curves.easeOut.transform((t * 2.5).clamp(0.0, 1.0)),
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - rise)),
            child: Transform.scale(scale: 0.9 + 0.1 * rise, child: child),
          ),
        );
      },
    );
  }
}
