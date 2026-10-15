import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/logger.dart';
import 'permission_backend.dart';
import 'permission_kind.dart';

/// Where a permission flow stands.
///
/// ```
///   checking ─┬─ all granted ───────────────────────────► granted
///             ├─ not asked / denied ─► primer ─ allow ─► requesting ─┬► granted
///             │                                                     ├► denied ─ try again ─► requesting
///             │                                                     └► blocked
///             └─ blocked by the OS ──► primer (blocked) ─ open settings ─► settings
///   blocked ─ open settings ─► settings ─ back, granted ─► granted
///                                       └ back, still off ─► blocked
///   any open phase ─ not now ─► dismissed
/// ```
enum PermissionFlowPhase {
  /// Reading the current status; nothing is shown yet.
  checking,

  /// The explanation, before the operating system is asked.
  primer,

  /// The operating system's own dialog is up.
  requesting,

  /// Everything asked for is usable. Terminal.
  granted,

  /// Refused, but the operating system will ask again.
  denied,

  /// Refused for good: only the system settings can change it now.
  blocked,

  /// The system settings were opened; waiting for the person to come back.
  settings,

  /// The person chose "not now". Terminal.
  dismissed,
}

/// The state machine behind the permission primer, free of any UI so it can
/// be tested against a fake [PermissionBackend].
class PermissionFlowController extends ChangeNotifier {
  PermissionFlowController({
    required List<Permission> permissions,
    required this.kind,
    required PermissionBackend backend,
  }) : permissions = List.unmodifiable(permissions),
       _backend = backend;

  /// Everything the caller needs; the flow only ever asks for what is
  /// still missing out of it.
  final List<Permission> permissions;

  /// What the caller asked for. See [visualKind] for what is shown.
  final PermissionKind kind;

  final PermissionBackend _backend;

  PermissionFlowPhase _phase = PermissionFlowPhase.checking;
  PermissionFlowPhase get phase => _phase;

  Map<Permission, PermissionStatus> _statuses = const {};
  Map<Permission, PermissionStatus> get statuses => _statuses;

  /// The primer opened on a permission the operating system already refuses
  /// to ask about, so its main action is "open settings" rather than
  /// "allow".
  bool _blockedAtStart = false;
  bool get blockedAtStart => _blockedAtStart;

  /// Whether the primer was ever needed. False when everything was already
  /// granted at [start] — the caller then continues without any UI.
  bool _needed = false;
  bool get needed => _needed;

  /// How many times the operating system was asked during this flow.
  int _requests = 0;
  int get requestCount => _requests;

  bool _busy = false;

  List<Permission> get missing => [
    for (final p in permissions)
      if (!(_statuses[p]?.isUsable ?? false)) p,
  ];

  bool get allGranted => missing.isEmpty;

  /// The kind the visuals and copy speak about: location when that is the
  /// only thing this phone's Android actually asks for.
  PermissionKind get visualKind {
    final m = missing;
    return PermissionKind.visualFor(kind, m.isEmpty ? permissions : m);
  }

  bool get isTerminal =>
      _phase == PermissionFlowPhase.granted ||
      _phase == PermissionFlowPhase.dismissed;

  /// Reads the current status and decides whether a primer is needed.
  Future<void> start() async {
    if (_phase != PermissionFlowPhase.checking) return;
    await _read();
    if (allGranted) {
      _go(PermissionFlowPhase.granted);
      return;
    }
    _needed = true;
    _blockedAtStart = missing.any((p) => _statuses[p]?.isBlocked ?? false);
    _go(PermissionFlowPhase.primer);
  }

  /// The primer's main action: ask the operating system, or — when it will
  /// not ask any more — go to the settings instead.
  Future<void> allow() async {
    if (_phase != PermissionFlowPhase.primer) return;
    if (_blockedAtStart) return openSettings();
    await _request();
  }

  /// The denied state's main action.
  Future<void> retry() async {
    if (_phase != PermissionFlowPhase.denied) return;
    await _request();
  }

  Future<void> openSettings() async {
    if (_phase != PermissionFlowPhase.primer &&
        _phase != PermissionFlowPhase.blocked &&
        _phase != PermissionFlowPhase.settings) {
      return;
    }
    _go(PermissionFlowPhase.settings);
    try {
      await _backend.openSettings();
    } catch (error) {
      Logger.diagnostic('permission: settings failed ${error.runtimeType}');
      _go(PermissionFlowPhase.blocked);
    }
  }

  /// The app came back to the foreground. Only meaningful after the system
  /// settings were opened: anything granted there is picked up without the
  /// person having to say so.
  Future<void> recheck() async {
    if (_phase != PermissionFlowPhase.settings &&
        _phase != PermissionFlowPhase.blocked &&
        _phase != PermissionFlowPhase.denied) {
      return;
    }
    await _read();
    if (isTerminal) return;
    if (allGranted) {
      _go(PermissionFlowPhase.granted);
    } else if (_phase == PermissionFlowPhase.settings) {
      _go(PermissionFlowPhase.blocked);
    }
  }

  void notNow() {
    if (isTerminal) return;
    _go(PermissionFlowPhase.dismissed);
  }

  Future<void> _request() async {
    if (_busy) return;
    _busy = true;
    final asking = missing;
    _go(PermissionFlowPhase.requesting);
    try {
      _requests++;
      final result = await _backend.request(asking);
      _statuses = {..._statuses, ...result};
    } catch (error) {
      // No backend (an unsupported platform, a plugin missing): read what is
      // there rather than inventing an answer.
      Logger.diagnostic('permission: request failed ${error.runtimeType}');
      await _read();
    } finally {
      _busy = false;
    }
    if (isTerminal) return;
    if (allGranted) {
      _go(PermissionFlowPhase.granted);
    } else if (missing.any((p) => _statuses[p]?.isBlocked ?? false)) {
      _go(PermissionFlowPhase.blocked);
    } else {
      _go(PermissionFlowPhase.denied);
    }
  }

  Future<void> _read() async {
    try {
      _statuses = {..._statuses, ...await _backend.statuses(permissions)};
    } catch (error) {
      Logger.diagnostic('permission: status failed ${error.runtimeType}');
    }
  }

  void _go(PermissionFlowPhase next) {
    if (_phase == next) return;
    _phase = next;
    notifyListeners();
  }
}
