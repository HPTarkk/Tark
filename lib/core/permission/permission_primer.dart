import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/logger.dart';
import 'permission_backend.dart';
import 'permission_flow.dart';
import 'permission_kind.dart';
import 'permission_primer_sheet.dart';

export 'permission_backend.dart' show PermissionStatusReading;
export 'permission_kind.dart';

/// The one door every runtime permission request in the app goes through.
///
/// Before the operating system's dialog, the person sees why the app wants
/// it — in the primer sheet, with a scene that is about *this* permission —
/// and only "Allow" raises the real dialog. A refusal lands on a calm
/// explanation with a way back ("Try again", or "Open settings" once Android
/// stops asking), and a grant gets a short success beat before the original
/// action carries on by itself.
///
/// A drop-in for `PermissionQueue.run(() => permissions.request())`: it
/// answers with the same status map, so every caller keeps its own handling
/// of the outcome. Permissions that are already granted never show anything.
///
/// When there is nothing to show the primer on (no navigator yet, an
/// unsupported platform, a plugin that is not there in tests), it falls back
/// to asking the operating system directly, exactly as the app always did —
/// the primer is an explanation, never a new way to get stuck.
abstract final class PermissionPrimer {
  /// Where statuses are read and dialogs raised. Replaced in tests.
  static PermissionBackend backend = const PluginPermissionBackend();

  /// The app's root navigator context, for requests made away from any
  /// widget (an audio engine starting, a cubit raising a hotspot). Set by the
  /// composition root.
  static BuildContext? Function()? hostContext;

  /// Overrides which kinds get a primer on this platform. Tests only.
  @visibleForTesting
  static bool Function(PermissionKind kind)? supportedOverride;

  /// One primer on screen at a time. Two callers asking at once — the
  /// Bluetooth page and the walkie session's microphone, say — are shown one
  /// after the other instead of stacked.
  static Future<void>? _tail;

  /// Asks for [permissions], explaining them first as [kind] (inferred from
  /// the permissions when omitted). [context] places the sheet; without one
  /// it goes on the app's root navigator.
  static Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions, {
    PermissionKind? kind,
    BuildContext? context,
  }) async {
    final resolvedKind = kind ?? PermissionKind.of(permissions);
    if (permissions.isEmpty) return const {};
    // The sheet always goes on the root navigator; the caller's context only
    // says which one that is. Taken now, before anything is awaited.
    final callerNavigator = context == null
        ? null
        : Navigator.maybeOf(context, rootNavigator: true);
    if (!supports(resolvedKind)) return backend.request(permissions);

    final Map<Permission, PermissionStatus> before;
    try {
      before = await backend.statuses(permissions);
    } catch (error) {
      // No readable status (tests without the plugin, an exotic platform):
      // behave exactly as before the primer existed.
      Logger.diagnostic('permission: status unavailable ${error.runtimeType}');
      return backend.request(permissions);
    }
    if (permissions.every((p) => before[p]?.isUsable ?? false)) return before;

    final completer = Completer<Map<Permission, PermissionStatus>>();
    final previous = _tail;
    final mine = completer.future.then<void>((_) {}, onError: (Object _) {});
    _tail = mine;
    if (previous != null) await previous;

    try {
      completer.complete(
        await _present(permissions, resolvedKind, callerNavigator, before),
      );
    } catch (error, stack) {
      completer.completeError(error, stack);
    } finally {
      if (identical(_tail, mine)) _tail = null;
    }
    return completer.future;
  }

  /// [request], answered as one bool: is everything usable now.
  static Future<bool> ensure(
    List<Permission> permissions, {
    PermissionKind? kind,
    BuildContext? context,
  }) async {
    final statuses = await request(permissions, kind: kind, context: context);
    return permissions.every((p) => statuses[p]?.isUsable ?? false);
  }

  static Future<Map<Permission, PermissionStatus>> _present(
    List<Permission> permissions,
    PermissionKind kind,
    NavigatorState? callerNavigator,
    Map<Permission, PermissionStatus> before,
  ) async {
    if (_host(callerNavigator) == null) {
      Logger.diagnostic('permission: no host for primer, asking directly');
      return backend.request(permissions);
    }

    final flow = PermissionFlowController(
      permissions: permissions,
      kind: kind,
      backend: backend,
    );
    await flow.start();
    // Granted while this one waited behind another primer.
    if (flow.allGranted) {
      final statuses = flow.statuses;
      flow.dispose();
      return statuses;
    }
    final host = _host(callerNavigator);
    if (host == null || !host.mounted) {
      flow.dispose();
      return before;
    }
    Logger.diagnostic('permission: primer ${flow.visualKind.name}');
    await showPermissionPrimerSheet(host, flow);
    final statuses = flow.statuses;
    Logger.diagnostic(
      'permission: primer ${flow.visualKind.name} -> ${flow.phase.name}',
    );
    flow.dispose();
    return statuses;
  }

  /// Where the sheet goes: the caller's navigator while it is still there
  /// (it may have gone while this waited its turn), else the app's root.
  static BuildContext? _host(NavigatorState? callerNavigator) {
    if (callerNavigator != null && callerNavigator.mounted) {
      return callerNavigator.context;
    }
    final root = hostContext?.call();
    return (root != null && root.mounted) ? root : null;
  }

  /// Whether [kind] is explained by a primer on this platform. Where it is
  /// not, the plugin that needs the permission asks for it itself.
  static bool supports(PermissionKind kind) {
    final override = supportedOverride;
    if (override != null) return override(kind);
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      // Only the microphone is compiled into permission_handler on iOS (see
      // the Podfile); everything else is asked by the plugin that uses it.
      TargetPlatform.iOS => kind == PermissionKind.microphone,
      _ => false,
    };
  }

  /// Forgets any queued primer. Tests only.
  @visibleForTesting
  static void resetForTest() {
    _tail = null;
    backend = const PluginPermissionBackend();
    hostContext = null;
    supportedOverride = null;
  }
}
