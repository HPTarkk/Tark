import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/connection_history.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../../room/api/room_api.dart';
import '../../../transfer/api/transfer_api.dart';

/// Landing's one question after the app stopped in the middle of a Room's
/// call: "Get back to Ali?".
///
/// It asks rather than reconnecting on its own, because opening the app is
/// not always wanting to be back on the call. It asks once per app start, and
/// "Not now" forgets the call for good.
abstract final class RoomRejoinPrompt {
  static bool _asked = false;

  static Future<void> maybeAsk(
    BuildContext context, {
    RoomRejoinTicketStore? tickets,
    RoomRepository? rooms,
  }) async {
    if (_asked || RoomRejoinTicketStore.savedThisRun) return;
    _asked = true;
    final store = tickets ?? RoomRejoinTicketStore();
    final repository =
        rooms ??
        (GetIt.instance.isRegistered<RoomRepository>()
            ? GetIt.instance<RoomRepository>()
            : null);
    if (repository == null) return;
    final ticket = await store.read();
    if (ticket == null) return;
    if (!ticket.isFresh(DateTime.now())) {
      await store.clear();
      return;
    }
    final SavedRoom? saved;
    try {
      saved = await repository.get(ticket.roomId);
    } catch (_) {
      return;
    }
    if (saved == null || saved.room.archived || !saved.membership.active) {
      await store.clear();
      return;
    }
    if (ticket.mode == TransferMode.bluetooth && await _bluetoothResumed()) {
      // The cold start already opened the Bluetooth resume screen for this
      // very call; a second question would be asking twice.
      return;
    }
    if (!context.mounted) return;
    final s = context.getString;
    final local = saved.membership.localMemberId;
    final others = saved.room.confirmedMembers
        .where((member) => member.id != local)
        .toList(growable: false);
    final title = others.length == 1
        ? s.rejoin_prompt_title_person(
            roomMemberDisplayName(
              others.single,
              fa: Localizations.localeOf(context).languageCode == 'fa',
              unnamed: s.people_unnamed,
            ),
          )
        : s.rejoin_prompt_title_room(saved.room.name);
    ScreenLog.tap('RejoinAsked');
    final go = await showConfirmSheet(
      context,
      title: title,
      body: s.rejoin_prompt_body(saved.room.name),
      action: s.rejoin_prompt_go,
      icon: Icons.replay_rounded,
      cancelLabel: s.rejoin_prompt_not_now,
    );
    if (!go) {
      ScreenLog.tap('RejoinNotNow');
      await store.clear();
      return;
    }
    ScreenLog.tap('RejoinGo');
    try {
      await repository.select(ticket.roomId);
    } catch (_) {
      // Deleted in the meantime; the walkie route says so itself.
    }
    if (!context.mounted) return;
    unawaited(
      context.push(
        ticket.mode == TransferMode.bluetooth
            ? AppRoutes.bluetoothResumePath
            : '${AppRoutes.walkiePath}?rejoin=true',
      ),
    );
  }

  /// Mirrors the cold-start rule that opens the Bluetooth resume screen.
  static Future<bool> _bluetoothResumed() async {
    if (!Platform.isAndroid) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return ConnectionHistory(
        prefs,
      ).shouldResumeClassicBluetooth(isAndroid: Platform.isAndroid);
    } catch (_) {
      return false;
    }
  }
}
