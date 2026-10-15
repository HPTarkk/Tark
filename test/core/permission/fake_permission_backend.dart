import 'dart:async';

import 'package:permission_handler/permission_handler.dart';
import 'package:tark/core/permission/permission_backend.dart';

/// A scripted [PermissionBackend]: [current] is what a status read returns,
/// and each [request] answers with the next entry of [answers] (or grants
/// everything once the script runs out).
class FakePermissionBackend implements PermissionBackend {
  FakePermissionBackend({
    Map<Permission, PermissionStatus>? current,
    List<PermissionStatus>? answers,
    this.throwOnStatus = false,
  }) : current = {...?current},
       answers = [...?answers];

  final Map<Permission, PermissionStatus> current;
  final List<PermissionStatus> answers;
  final bool throwOnStatus;

  int requests = 0;
  int statusReads = 0;
  int settingsOpened = 0;
  final List<List<Permission>> asked = [];

  /// When set, [request] waits on this before answering — the OS dialog
  /// being up.
  Completer<void>? dialog;

  @override
  Future<Map<Permission, PermissionStatus>> statuses(
    List<Permission> permissions,
  ) async {
    statusReads++;
    if (throwOnStatus) throw StateError('no plugin');
    return {
      for (final p in permissions) p: current[p] ?? PermissionStatus.denied,
    };
  }

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) async {
    requests++;
    asked.add(permissions);
    await dialog?.future;
    final answer = answers.isEmpty
        ? PermissionStatus.granted
        : answers.removeAt(0);
    for (final p in permissions) {
      current[p] = answer;
    }
    return {for (final p in permissions) p: answer};
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}
