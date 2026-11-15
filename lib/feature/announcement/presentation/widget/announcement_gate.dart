import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/motion/screen_calm.dart';
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
/// - **Only once the screen is still.** It is its own moment, never part of
///   the app arriving: it waits for the route transition to finish, for
///   Home's entrance (and any question Home asks straight after it) to play
///   out, for no sheet or dialog to be open, and for the app to be in front.
///   Then one more beat ([settle]), and never sooner than [earliest] after
///   launch. Leaving Home, a sheet opening, or the app going to the
///   background in that wait starts it over.
/// - **Failure: never.** No signal, a broken file — nothing shows.
class AnnouncementGate extends StatefulWidget {
  const AnnouncementGate({
    required this.child,
    required this.location,
    required this.locationChanges,
    required this.updateOffered,
    required this.navigate,
    ValueListenable<bool>? routesCalm,
    ValueListenable<int>? entrances,
    this.settle = const Duration(milliseconds: 1200),
    this.earliest = const Duration(seconds: 3),
    this.entranceCap = const Duration(seconds: 5),
    super.key,
  }) : routesCalm = routesCalm ?? const _Always(true),
       entrances = entrances ?? const _Always(0);

  final Widget child;

  /// The router's current path.
  final String Function() location;

  /// Fires when [location] may have changed.
  final Listenable locationChanges;

  /// Whether the update check found something to offer: null while it is
  /// still asking.
  final ValueListenable<bool?> updateOffered;

  final AnnouncementNavigate navigate;

  /// True while no route is moving and nothing is open over the page — see
  /// [RouteCalm]. Always calm when left out.
  final ValueListenable<bool> routesCalm;

  /// Entrances still playing — see [EntranceHold]. None when left out.
  final ValueListenable<int> entrances;

  /// The beat between everything going still and the sheet rising.
  final Duration settle;

  /// The soonest after this gate starts (the app opening) that the sheet
  /// may rise, however quickly everything else settles.
  final Duration earliest;

  /// How long an entrance may hold the sheet back. A screen that forgets to
  /// release its hold must not keep announcements away for the whole launch.
  final Duration entranceCap;

  /// Whether announcements are waiting to be shown this launch, or are on
  /// screen. Other asks (the rating story) stand aside for them rather than
  /// make one launch interrupt twice.
  static bool get claimed => _claimed;
  static bool _claimed = false;

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

class _AnnouncementGateState extends State<AnnouncementGate>
    with WidgetsBindingObserver {
  List<Announcement> _pending = const [];
  bool _done = false;

  /// The sheet is up. Once up, it stays until it is closed or the person
  /// leaves Home under it; only rising waits for everything to be still.
  bool _visible = false;

  /// [AnnouncementGate.earliest] has passed since launch.
  bool _launchOld = false;
  Timer? _earliestTimer;

  /// Everything has been still for [AnnouncementGate.settle].
  bool _settled = false;
  Timer? _settleTimer;
  Timer? _capTimer;
  bool _entranceCapped = false;
  bool _reconsiderQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen(widget);
    _earliestTimer = Timer(widget.earliest, () {
      _launchOld = true;
      _reconsider();
    });
    unawaited(_check());
  }

  void _listen(AnnouncementGate gate) {
    gate.locationChanges.addListener(_reconsiderSoon);
    gate.updateOffered.addListener(_reconsiderSoon);
    gate.routesCalm.addListener(_reconsiderSoon);
    gate.entrances.addListener(_reconsiderSoon);
  }

  void _unlisten(AnnouncementGate gate) {
    gate.locationChanges.removeListener(_reconsiderSoon);
    gate.updateOffered.removeListener(_reconsiderSoon);
    gate.routesCalm.removeListener(_reconsiderSoon);
    gate.entrances.removeListener(_reconsiderSoon);
  }

  @override
  void didUpdateWidget(AnnouncementGate old) {
    super.didUpdateWidget(old);
    _unlisten(old);
    _listen(widget);
    _reconsiderSoon();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlisten(widget);
    _earliestTimer?.cancel();
    _settleTimer?.cancel();
    _capTimer?.cancel();
    AnnouncementGate._claimed = false;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _reconsiderSoon();

  Future<void> _check() async {
    List<Announcement> found;
    try {
      found = await GetIt.instance<AnnouncementChecker>().check();
    } catch (_) {
      // Never let a feed take the app down with it.
      found = const [];
    }
    if (!mounted || found.isEmpty) return;
    _pending = found;
    _reconsider();
  }

  /// The notifiers this listens to can fire mid-build (a route pushed by the
  /// router, a page taking its entrance hold in initState), so the decision
  /// is made just after, never inside, the frame that changed them.
  void _reconsiderSoon() {
    if (_reconsiderQueued || !mounted) return;
    _reconsiderQueued = true;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      scheduleMicrotask(_runQueued);
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => _runQueued());
      SchedulerBinding.instance.ensureVisualUpdate();
    }
  }

  void _runQueued() {
    _reconsiderQueued = false;
    _reconsider();
  }

  /// Announcements are due on this screen: something new, not yet put away,
  /// no update taking this launch's one interruption, and Home is showing.
  bool get _wanted =>
      _pending.isNotEmpty &&
      !_done &&
      widget.updateOffered.value == false &&
      AnnouncementGate.homes.contains(widget.location());

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Nothing is moving, nothing is open, and the app is in front.
  bool get _still =>
      _foreground &&
      widget.routesCalm.value &&
      (widget.entrances.value == 0 || _entranceCapped);

  void _reconsider() {
    if (!mounted) return;
    AnnouncementGate._claimed =
        _pending.isNotEmpty && !_done && widget.updateOffered.value != true;
    if (widget.entrances.value == 0) {
      _capTimer?.cancel();
      _capTimer = null;
      _entranceCapped = false;
    }
    final wanted = _wanted;
    if (!wanted) {
      _cancelWait();
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (_visible) return;
    if (widget.entrances.value > 0 && !_entranceCapped) {
      _capTimer ??= Timer(widget.entranceCap, () {
        _capTimer = null;
        _entranceCapped = true;
        _reconsider();
      });
    }
    if (!_still) {
      // Something moved or opened: the beat starts over once it is still.
      _cancelWait();
      return;
    }
    if (_settled && _launchOld) {
      setState(() => _visible = true);
      return;
    }
    if (_settled || _settleTimer != null) return;
    _settleTimer = Timer(widget.settle, () {
      _settleTimer = null;
      _settled = true;
      _reconsider();
    });
  }

  void _cancelWait() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _settled = false;
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: widget.child),
      if (_visible)
        Positioned.fill(
          child: AnnouncementSheet(
            announcements: _pending,
            onSeen: (a) => unawaited(
              GetIt.instance<AnnouncementChecker>().markSeen([a.id]),
            ),
            onClosed: () {
              setState(() {
                _done = true;
                _visible = false;
              });
              AnnouncementGate._claimed = false;
            },
            navigate: widget.navigate,
          ),
        ),
    ],
  );
}

class _Always<T> implements ValueListenable<T> {
  const _Always(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
