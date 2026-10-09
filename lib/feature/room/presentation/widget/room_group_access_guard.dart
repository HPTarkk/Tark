import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../domain/entity/room.dart';
import '../../domain/repository/room_repository.dart';

/// Stops a free session when a third confirmed member arrives, or when the
/// local subscription expires. Each participant checks their own entitlement;
/// the decorative premium badge on a remote member is never authorization.
class RoomGroupAccessGuard extends StatefulWidget {
  const RoomGroupAccessGuard({
    required this.room,
    required this.builder,
    required this.onBlocked,
    this.repository,
    super.key,
  });
  final SavedRoom room;
  final WidgetBuilder builder;
  final ValueChanged<SavedRoom> onBlocked;
  final RoomRepository? repository;

  @override
  State<RoomGroupAccessGuard> createState() => _RoomGroupAccessGuardState();
}

class _RoomGroupAccessGuardState extends State<RoomGroupAccessGuard> {
  late SavedRoom _room = widget.room;
  LicenseGate? _gate;
  StreamSubscription<void>? _accessChanges;
  StreamSubscription<void>? _roomChanges;
  bool _reported = false;
  int _read = 0;

  bool get _allowed =>
      !RoomAccessPolicy.requiresPremium(_room.room.confirmedMembers.length) ||
      (_gate?.allows(PremiumFeature.groupRooms) ?? true);

  @override
  void initState() {
    super.initState();
    if (GetIt.instance.isRegistered<LicenseGate>()) {
      _gate = GetIt.instance<LicenseGate>();
    }
    _accessChanges = _gate?.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _roomChanges = widget.repository?.changes.listen(
      (_) => unawaited(_reload()),
    );
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final read = ++_read;
    try {
      final next = await widget.repository?.get(_room.room.id);
      if (mounted && read == _read && next != null) {
        setState(() => _room = next);
      }
    } catch (_) {
      // Keep the last confirmed roster on a transient storage failure.
    }
  }

  @override
  void didUpdateWidget(RoomGroupAccessGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room != widget.room) _room = widget.room;
  }

  @override
  void dispose() {
    unawaited(_accessChanges?.cancel());
    unawaited(_roomChanges?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed) {
      _reported = false;
      return widget.builder(context);
    }
    if (!_reported) {
      _reported = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_allowed) widget.onBlocked(_room);
      });
    }
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
