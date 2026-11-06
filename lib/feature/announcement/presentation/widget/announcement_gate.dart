import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/router/routes.dart';
import '../../data/announcement_checker.dart';
import '../../domain/entity/announcement.dart';
import 'announcement_sheet.dart';

/// Opens a screen by its route name; the gate sits above the navigator, so
/// it is handed one rather than looking for one.
typedef AnnouncementNavigate = void Function(String routeName);

/// Asks for announcements once per launch and, when there are new ones,
/// brings them up over the home screen.
///
/// Sits in `MaterialApp.builder` just inside the [UpdateGate], and follows
/// the same rules about *when*, plus one of its own:
/// - **Only on the home and room-list screens.** Never over the splash, a
///   channel, or a flow someone is in the middle of.
/// - **After the update question is answered, and only if it was "no".**
///   One launch interrupts once: an update matters more, and a second sheet
///   straight after the first is the app talking over its rider. The
///   announcements wait for the next launch.
/// - **Failure: never.** No signal, a broken file — nothing shows.
class AnnouncementGate extends StatefulWidget {
  const AnnouncementGate({
    required this.child,
    required this.location,
    required this.locationChanges,
    required this.updateOffered,
    required this.navigate,
    super.key,
  });

  final Widget child;

  /// The router's current path.
  final String Function() location;

  /// Fires when [location] may have changed.
  final Listenable locationChanges;

  /// Whether the update check found something to offer: null while it is
  /// still asking.
  final ValueListenable<bool?> updateOffered;

  final AnnouncementNavigate navigate;

  /// The screens an announcement's `screen` action may open.
  static const screens = {
    'settings': AppRoutes.settingsName,
    'profile': AppRoutes.profileName,
    'rooms': AppRoutes.roomsName,
    'advanced': AppRoutes.advancedSettingsName,
  };

  static const homes = {AppRoutes.landingPath, AppRoutes.roomsPath};

  @override
  State<AnnouncementGate> createState() => _AnnouncementGateState();
}

class _AnnouncementGateState extends State<AnnouncementGate> {
  List<Announcement> _pending = const [];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.locationChanges.addListener(_refresh);
    widget.updateOffered.addListener(_refresh);
    unawaited(_check());
  }

  @override
  void didUpdateWidget(AnnouncementGate old) {
    super.didUpdateWidget(old);
    if (old.locationChanges != widget.locationChanges) {
      old.locationChanges.removeListener(_refresh);
      widget.locationChanges.addListener(_refresh);
    }
    if (old.updateOffered != widget.updateOffered) {
      old.updateOffered.removeListener(_refresh);
      widget.updateOffered.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.locationChanges.removeListener(_refresh);
    widget.updateOffered.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _check() async {
    List<Announcement> found;
    try {
      found = await GetIt.instance<AnnouncementChecker>().check();
    } catch (_) {
      // Never let a feed take the app down with it.
      found = const [];
    }
    if (!mounted || found.isEmpty) return;
    setState(() => _pending = found);
  }

  void _refresh() {
    if (_pending.isNotEmpty && mounted) setState(() {});
  }

  bool get _show =>
      _pending.isNotEmpty &&
      !_done &&
      widget.updateOffered.value == false &&
      AnnouncementGate.homes.contains(widget.location());

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: widget.child),
      if (_show)
        Positioned.fill(
          child: AnnouncementSheet(
            announcements: _pending,
            onSeen: (a) => unawaited(
              GetIt.instance<AnnouncementChecker>().markSeen([a.id]),
            ),
            onClosed: () => setState(() => _done = true),
            navigate: widget.navigate,
          ),
        ),
    ],
  );
}
