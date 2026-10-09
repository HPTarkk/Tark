import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/route_arrival.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/localized_counter.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';
import '../widget/room_formation.dart';
import '../widget/room_visuals.dart';

class RoomCreatePage extends StatefulWidget {
  const RoomCreatePage({super.key});
  @override
  State<RoomCreatePage> createState() => _RoomCreatePageState();
}

class _RoomCreatePageState extends State<RoomCreatePage>
    with SingleTickerProviderStateMixin, RouteArrival<RoomCreatePage> {
  final _name = TextEditingController();
  late final _arrival = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );
  bool _busy = false, _ready = false;
  String? _error;
  bool get _locked {
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
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || _ready || _name.text.trim().isEmpty) return;
    final cubit = context.read<RoomListCubit>();
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
      HapticFeedback.mediumImpact();
      setState(() => _ready = true);
      await Future<void>.delayed(
        AppMotion.reduced(context)
            ? const Duration(milliseconds: 500)
            : const Duration(milliseconds: 1000),
      );
      if (mounted) Navigator.of(context).pop<SavedRoom>(created);
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
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return PopScope(
      canPop: !_busy && !_ready,
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
                              : () => Navigator.of(context).pop(),
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
                          RoomFormation(assembling: _busy, ready: _ready),
                        ),
                        _enter(
                          1,
                          AnimatedSwitcher(
                            duration: AppMotion.card,
                            child: Text(
                              _ready
                                  ? s.room_create_ready
                                  : s.room_create_title,
                              key: ValueKey(_ready),
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
                        const SizedBox(height: 30),
                        _enter(
                          2,
                          TextField(
                            key: const Key('room-name-field'),
                            controller: _name,
                            enabled: !_busy && !_ready,
                            maxLength: 48,
                            buildCounter: localizedCounter(),
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
                                borderSide: BorderSide(color: AppColors.border),
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
                        _enter(
                          3,
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _locked
                                    ? Icons.workspace_premium_rounded
                                    : Icons.lock_outline_rounded,
                                size: 16,
                                color: AppColors.textSecondary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _locked
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
                              : _locked
                              ? s.lobby_unlock_premium
                              : s.rooms_create,
                          busy: _busy && !_ready,
                          icon: _ready
                              ? Icons.check_rounded
                              : _locked
                              ? Icons.workspace_premium_rounded
                              : Icons.add_rounded,
                          onTap: _busy || _ready || _name.text.trim().isEmpty
                              ? null
                              : () => unawaited(_create()),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
