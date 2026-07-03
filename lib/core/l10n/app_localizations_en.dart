// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get app_name => 'TARK';

  @override
  String get app_subtitle => 'LAN WALKIE TALKIE';

  @override
  String get live => 'LIVE';

  @override
  String get offline => 'OFFLINE';

  @override
  String get edit_name => 'EDIT';

  @override
  String get connecting => 'Connecting...';

  @override
  String get monitoring => 'MONITORING';

  @override
  String get initializing => 'INITIALIZING';

  @override
  String get tx_label => 'TX';

  @override
  String get rx_label => 'RX';

  @override
  String get channel_members => 'CHANNEL MEMBERS';

  @override
  String get no_users_on_network => 'No other users on this network';

  @override
  String get vox_sensitivity => 'VOX SENSITIVITY';

  @override
  String get vox_threshold => 'THRESHOLD';

  @override
  String get voice_loud => 'LOUD';

  @override
  String get voice_quiet => 'QUIET';

  @override
  String get level_label => 'LEVEL';

  @override
  String get level_active => 'ACTIVE';

  @override
  String get level_silent => 'SILENT';

  @override
  String get user_idle => 'IDLE';

  @override
  String get set_name_title => 'Set Your Name';

  @override
  String get name_hint => 'Enter your name';

  @override
  String get cancel => 'CANCEL';

  @override
  String get save => 'SAVE';

  @override
  String get mic_permission_denied =>
      'Microphone permission denied. Please enable it in Settings.';

  @override
  String get join_channel => 'JOIN CHANNEL';

  @override
  String get leave_channel => 'LEAVE CHANNEL';

  @override
  String get no_network => 'No network found';

  @override
  String get leave_channel_confirm_title => 'Leave channel?';

  @override
  String get leave_channel_confirm_message =>
      'You will be disconnected from the other members in this channel.';

  @override
  String get leave => 'LEAVE';

  @override
  String get transport_wifi => 'WIFI';

  @override
  String get transport_bluetooth => 'BLUETOOTH';

  @override
  String get bt_start_session => 'START SESSION';

  @override
  String get bt_find_nearby => 'FIND NEARBY';

  @override
  String get bt_waiting_for_peer => 'Waiting for the other side to connect...';

  @override
  String get bt_scanning => 'Scanning...';

  @override
  String get bt_no_devices_found => 'No devices found';

  @override
  String get bt_connecting => 'Connecting...';

  @override
  String get bt_connected => 'Connected';

  @override
  String get bt_permission_denied =>
      'Bluetooth permission denied. Please enable it in Settings.';

  @override
  String get bt_connection_failed => 'Connection failed';

  @override
  String get bt_back => 'BACK';

  @override
  String get theme_dark => 'DARK';

  @override
  String get theme_light => 'LIGHT';

  @override
  String get noise_filter => 'NOISE FILTER';

  @override
  String get noise_filter_off => 'OFF';

  @override
  String get noise_filter_weak => 'LOW';

  @override
  String get noise_filter_strong => 'HIGH';
}
