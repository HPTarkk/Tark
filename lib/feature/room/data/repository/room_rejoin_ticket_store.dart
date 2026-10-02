import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/settings/settings_keys.dart';
import '../../../../core/utils/logger.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room.dart';

/// What a phone needs to get back into a live Room after its app stopped
/// without a Leave: a phone call, the app swiped away, the battery saver.
///
/// Written when a Room goes live, removed when the call ends on purpose
/// (Leave, the alone countdown) or once Landing has asked about it. So a
/// ticket that is still there at the next app start means the call ended by
/// accident.
@immutable
class RoomRejoinTicket {
  const RoomRejoinTicket({
    required this.roomId,
    required this.mode,
    required this.side,
    required this.at,
    this.credentials,
  });

  /// After this long the others have most likely left too: a phone alone in
  /// a Room leaves by itself after ten minutes and a one-minute countdown.
  static const maxAge = Duration(minutes: 30);

  final RoomId roomId;

  /// The connection the call ran on. Rejoining uses the same one, never
  /// another.
  final TransferMode mode;

  /// Which end of a shared connection this phone was: [SessionRole.host]
  /// shared it, [SessionRole.joiner] joined someone else's.
  final SessionRole side;
  final DateTime at;

  /// The shared connection this phone had joined, so it can join it again
  /// without a code while the other phone still holds it up. Only for a
  /// joiner on [TransferMode.hotspot]; kept in sealed storage, never in
  /// preferences.
  final HotspotCredentials? credentials;

  bool isFresh(DateTime now) => now.difference(at) < maxAge;

  RoomRejoinTicket withCredentials(HotspotCredentials? credentials) =>
      RoomRejoinTicket(
        roomId: roomId,
        mode: mode,
        side: side,
        at: at,
        credentials: credentials,
      );
}

/// Sealed storage for a [RoomRejoinTicket]'s network details.
abstract interface class RoomRejoinSecrets {
  Future<void> write(HotspotCredentials credentials);
  Future<HotspotCredentials?> read();
  Future<void> delete();
}

/// The Android-Keystore-sealed file the Room identity keys use, under a name
/// of its own. Anywhere without it (iOS, tests, desktop) nothing is kept and
/// the rejoin falls back to the code screen.
final class PlatformRoomRejoinSecrets implements RoomRejoinSecrets {
  PlatformRoomRejoinSecrets({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('tark/room_identity_secure_storage');

  final MethodChannel _channel;

  @override
  Future<void> write(HotspotCredentials credentials) async {
    try {
      await _channel.invokeMethod<void>('writeRejoin', {
        'material': {
          'ssid': credentials.ssid,
          'passphrase': credentials.passphrase,
          'security': credentials.security,
        },
      });
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<HotspotCredentials?> read() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('readRejoin');
      if (raw is! Map) return null;
      final ssid = raw['ssid'];
      final passphrase = raw['passphrase'];
      final security = raw['security'];
      if (ssid is! String || ssid.isEmpty || passphrase is! String) {
        return null;
      }
      return HotspotCredentials(
        ssid: ssid,
        passphrase: passphrase,
        security: security is String && security.isNotEmpty ? security : 'WPA',
      );
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _channel.invokeMethod<void>('deleteRejoin');
    } on MissingPluginException {
      return;
    }
  }
}

/// Keeps the one [RoomRejoinTicket] this phone can have.
class RoomRejoinTicketStore {
  RoomRejoinTicketStore({
    Future<SharedPreferences> Function()? prefs,
    RoomRejoinSecrets? secrets,
  }) : _prefs = prefs ?? SharedPreferences.getInstance,
       _secrets = secrets ?? PlatformRoomRejoinSecrets();

  final Future<SharedPreferences> Function() _prefs;
  final RoomRejoinSecrets _secrets;

  /// A Room went live in this run of the app. Any ticket on disk is then
  /// this run's own (or already cleared), never one left by an app that
  /// stopped, so there is nothing to offer.
  static bool savedThisRun = false;

  Future<void> save(RoomRejoinTicket ticket) async {
    savedThisRun = true;
    try {
      final credentials = ticket.credentials;
      if (credentials == null) {
        await _secrets.delete();
      } else {
        await _secrets.write(credentials);
      }
      await (await _prefs()).setString(
        SettingsKeys.roomRejoinTicket,
        jsonEncode({
          'room': ticket.roomId.value,
          'mode': ticket.mode.key,
          'side': ticket.side.name,
          'at': ticket.at.millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      Logger.log('Saving the rejoin ticket failed: $e');
    }
  }

  /// The ticket, or null when there is none or it cannot be read.
  Future<RoomRejoinTicket?> read() async {
    try {
      final raw = (await _prefs()).getString(SettingsKeys.roomRejoinTicket);
      if (raw == null) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final room = json['room'];
      final mode = json['mode'];
      final at = json['at'];
      if (room is! String || mode is! String || at is! int) return null;
      final side = SessionRole.values.firstWhere(
        (role) => role.name == json['side'],
        orElse: () => SessionRole.unknown,
      );
      final ticket = RoomRejoinTicket(
        roomId: RoomId(room),
        mode: TransferMode.fromKey(mode),
        side: side,
        at: DateTime.fromMillisecondsSinceEpoch(at),
      );
      if (ticket.mode != TransferMode.hotspot || side != SessionRole.joiner) {
        return ticket;
      }
      HotspotCredentials? credentials;
      try {
        credentials = await _secrets.read();
      } catch (e) {
        Logger.log('Reading the rejoin network failed: $e');
      }
      return ticket.withCredentials(credentials);
    } catch (e) {
      Logger.log('Reading the rejoin ticket failed: $e');
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await (await _prefs()).remove(SettingsKeys.roomRejoinTicket);
      await _secrets.delete();
    } catch (e) {
      Logger.log('Clearing the rejoin ticket failed: $e');
    }
  }
}
