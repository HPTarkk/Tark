// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get app_name => 'TARKK';

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
  String get music_cast => 'MUSIC CAST';

  @override
  String get music_cast_hint =>
      'Cast this phone\'s music and app sounds to everyone on the channel.';

  @override
  String get music_cast_start => 'START CASTING';

  @override
  String get music_cast_starting => 'STARTING...';

  @override
  String get music_cast_stop => 'STOP';

  @override
  String get music_cast_on_air => 'ON AIR';

  @override
  String get music_cast_mix => 'MIX LEVEL';

  @override
  String get music_cast_silent =>
      'Nothing is playing — start a song in your music app';

  @override
  String get music_cast_stop_hint =>
      'Enable notification access so Stop also pauses the music app';

  @override
  String get music_cast_stop_enable => 'ENABLE';

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
  String get transport_wifi_hotspot => 'WIFI / HOTSPOT';

  @override
  String get transport_bluetooth => 'BLUETOOTH';

  @override
  String get transport_guest => 'GUEST';

  @override
  String get guest_invite_title => 'Invite a guest';

  @override
  String get guest_step_scan =>
      'The guest scans this code with their phone camera — the join page opens in their browser.';

  @override
  String get guest_step_answer =>
      'Their screen then shows a reply code — scan it with the button below, or paste it if they sent it to you instead.';

  @override
  String get guest_scan_answer => 'SCAN REPLY CODE';

  @override
  String get guest_link_failed =>
      'The link could not be established. Create a new invite and try again.';

  @override
  String get guest_no_server_badge => 'NO SERVER';

  @override
  String get guest_copy_link => 'COPY LINK';

  @override
  String get guest_link_copied => 'Invite link copied';

  @override
  String get guest_paste_answer => 'PASTE THEIR REPLY INSTEAD';

  @override
  String get guest_paste_answer_hint => 'Paste the reply code they sent you';

  @override
  String get guest_paste_submit => 'CONNECT';

  @override
  String get guest_stun_caveat =>
      'Works over the internet on most networks. A few strict/corporate networks may still block the connection.';

  @override
  String get guest_web_scan_title => 'Scan to join';

  @override
  String get guest_web_scan_text =>
      'Open this page by scanning the invite QR code, or opening the invite link, from the host\'s phone.';

  @override
  String get guest_web_failed_title => 'Link failed';

  @override
  String get guest_web_failed_text =>
      'The connection could not be established. Ask the host to create a new invite and try again.';

  @override
  String get guest_web_reply_chip => 'STEP 2 — REPLY CODE';

  @override
  String get guest_web_reply_title => 'Show this code to the host phone';

  @override
  String get guest_web_reply_hint =>
      'On the host: tap \"SCAN REPLY CODE\" and point the camera here.';

  @override
  String get guest_web_reply_copy => 'COPY CODE';

  @override
  String get guest_web_reply_copied => 'Reply code copied';

  @override
  String get guest_web_connected => 'Connected!';

  @override
  String get guest_web_enable_audio =>
      'Tap below to enable your microphone and speaker.';

  @override
  String get guest_web_start_audio => 'START AUDIO';

  @override
  String get guest_web_mute => 'MUTE';

  @override
  String get guest_web_unmute => 'UNMUTE';

  @override
  String get guest_web_talking => 'Talking...';

  @override
  String get guest_web_on_air => 'You are on air';

  @override
  String get guest_web_standby => 'Standing by';

  @override
  String get guest_web_link_lost => 'LINK LOST';

  @override
  String get guest_web_link_lost_text => 'Link lost — waiting...';

  @override
  String get guest_web_left_title => 'You left the channel';

  @override
  String get guest_web_left_text =>
      'You\'ve disconnected. To rejoin, ask the host for a fresh invite and scan it again.';

  @override
  String get bt_start_session => 'START SESSION';

  @override
  String get bt_role_host_desc =>
      'Broadcast a session for the other device to find and join';

  @override
  String get bt_find_nearby => 'FIND NEARBY';

  @override
  String get bt_role_join_desc =>
      'Sweep the area and connect to a nearby session';

  @override
  String get bt_visible_as => 'VISIBLE AS';

  @override
  String get bt_last_session => 'LAST SESSION';

  @override
  String get bt_reconnect => 'RECONNECT';

  @override
  String get bt_link_reconnecting => 'Bluetooth link lost — reconnecting...';

  @override
  String get bt_link_down => 'Bluetooth link lost';

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
  String get bt_not_supported_platform =>
      'Bluetooth mode is not available on this device yet. Please use WiFi mode.';

  @override
  String get open_settings => 'OPEN SETTINGS';

  @override
  String get retry => 'TRY AGAIN';

  @override
  String get permissions_title => 'Permissions';

  @override
  String get permission_granted => 'Granted';

  @override
  String get permission_grant => 'GRANT';

  @override
  String get permission_mic_title => 'Microphone';

  @override
  String get permission_mic_desc =>
      'Needed to capture your voice for transmission.';

  @override
  String get permission_bluetooth_title => 'Bluetooth';

  @override
  String get permission_bluetooth_desc =>
      'Needed to scan for and connect to a nearby device in Bluetooth mode.';

  @override
  String get permission_bt_scan_title => 'Scan for devices';

  @override
  String get permission_bt_scan_desc => 'Finds nearby devices to connect to.';

  @override
  String get permission_bt_connect_title => 'Connect';

  @override
  String get permission_bt_connect_desc =>
      'Pairs and exchanges audio with the other device.';

  @override
  String get permission_bt_advertise_title => 'Advertise';

  @override
  String get permission_bt_advertise_desc =>
      'Lets the other device find you when you\'re hosting.';

  @override
  String get permission_hotspot_title => 'Location & nearby Wi-Fi';

  @override
  String get permission_hotspot_desc =>
      'Needed by Android to host a local hotspot for others to join.';

  @override
  String get permission_battery_title => 'Background battery exemption';

  @override
  String get permission_battery_desc =>
      'Keeps the channel alive when the screen is off — without it, the OS may freeze or kill the app mid-ride.';

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

  @override
  String get sfx_feedback => 'SOUND FEEDBACK';

  @override
  String get link_reconnecting => 'Connection lost — reconnecting...';

  @override
  String get link_down => 'Connection lost';

  @override
  String get transport_hotspot => 'HOTSPOT';

  @override
  String get hotspot_title => 'Hotspot bridge';

  @override
  String get wifi_only_instructions =>
      'Already on the same Wi-Fi? There\'s nothing to set up — just enter the channel.';

  @override
  String get wifi_only_step_same_network =>
      'Make sure both devices are connected to the same Wi-Fi network.';

  @override
  String get hotspot_not_supported =>
      'The hotspot bridge host runs on Android. On iPhone, join an Android host\'s hotspot instead.';

  @override
  String get hotspot_host_badge => 'LOCAL WIFI • ANDROID HOST';

  @override
  String get hotspot_creating => 'Creating hotspot...';

  @override
  String get hotspot_waiting => 'Waiting for the iPhone to join...';

  @override
  String get hotspot_step_scan =>
      'On the iPhone, scan this code (Camera or the in-app scanner) and tap Join.';

  @override
  String get hotspot_step_join_channel =>
      'It then enters the channel — audio flows over this Wi-Fi link.';

  @override
  String get hotspot_network => 'NETWORK';

  @override
  String get hotspot_password => 'PASSWORD';

  @override
  String get hotspot_copied => 'copied';

  @override
  String get hotspot_enter_channel => 'ENTER CHANNEL';

  @override
  String get hotspot_error =>
      'Couldn\'t create the hotspot. Turn off any active hotspot/tethering, make sure Location is on, then try again.';

  @override
  String get hotspot_ios_instructions =>
      'Ask the Android phone to open Tarkk → Hotspot, then scan its Wi-Fi code here.';

  @override
  String get hotspot_scan_host => 'SCAN HOST CODE';

  @override
  String get hotspot_joining => 'Joining network...';

  @override
  String get hotspot_joined => 'Joined the network';

  @override
  String get hotspot_manual_join_title => 'Join this network manually';

  @override
  String get hotspot_manual_join_hint =>
      'Open Settings › Wi-Fi, pick this network, then come back and enter the channel.';

  @override
  String get hotspot_invalid_qr =>
      'That isn\'t a Wi-Fi code. Scan the code shown on the Android host.';

  @override
  String get bt_ios_hint =>
      'iPhone ↔ Android over Bluetooth can be unreliable. For the most solid cross-phone link, use Hotspot mode.';

  @override
  String get bt_ble_unavailable =>
      'This phone can\'t advertise over Bluetooth LE, so iPhones won\'t find it here.';

  @override
  String get bt_use_wifi_bridge => 'USE WI-FI BRIDGE';

  @override
  String get background_title => 'Keep the channel alive with the screen off';

  @override
  String get background_desc =>
      'For riding, allow the app to run in the background so audio keeps flowing when the screen turns off. Without this, the phone may drop Wi-Fi and go silent.';

  @override
  String get background_allow => 'ALLOW BACKGROUND';

  @override
  String get background_autostart => 'AUTOSTART';

  @override
  String get background_dismiss => 'NOT NOW';

  @override
  String get music_cast_stalled =>
      'This phone\'s audio system blocks music sharing while a channel call is active. Stopped casting.';

  @override
  String get settings_title => 'Settings';

  @override
  String get settings_section_identity => 'PROFILE';

  @override
  String get settings_section_voice => 'VOICE & AUDIO';

  @override
  String get settings_section_sound => 'SOUND & ALERTS';

  @override
  String get settings_section_appearance => 'APPEARANCE';

  @override
  String get settings_section_connection => 'CONNECTION';

  @override
  String get settings_section_startup => 'STARTUP';

  @override
  String get settings_applies_live =>
      'Applies to your current channel instantly';

  @override
  String get settings_applies_next_session =>
      'Applies next time you join a channel';

  @override
  String get settings_quick_access => 'Quick access';

  @override
  String get settings_quick_access_desc =>
      'Skip this screen and resume your last channel on launch';

  @override
  String get settings_delay => 'PLAYBACK DELAY';

  @override
  String get settings_delay_desc =>
      'How much incoming audio is buffered before playback — higher smooths out a choppy connection at the cost of latency.';

  @override
  String get settings_restore_defaults => 'RESTORE DEFAULTS';

  @override
  String get settings_restore_defaults_done =>
      'Voice settings restored to defaults';

  @override
  String get settings_auto_reconnect => 'Auto-reconnect';

  @override
  String get settings_auto_reconnect_desc =>
      'Automatically retry when the link drops instead of requiring a manual retry';

  @override
  String get settings_permissions_row => 'Permissions';

  @override
  String get settings_permissions_row_desc =>
      'Review and manage what the app can access';

  @override
  String get settings_wifi_hotspot_row => 'WiFi / Hotspot setup';

  @override
  String get settings_wifi_hotspot_row_desc =>
      'Host a hotspot or check the WiFi join steps';

  @override
  String get settings_skip_splash => 'Skip splash screen';

  @override
  String get settings_skip_splash_desc => 'Go straight to the app on launch';

  @override
  String get usage_tips_title => 'Get the most out of TarkK';

  @override
  String get usage_tips_1_title => 'Pair an ANC or handsfree headset';

  @override
  String get usage_tips_1_body =>
      'Active noise cancellation makes it much easier to hear the channel over wind and engine noise — and keeps your hands free while riding.';

  @override
  String get usage_tips_2_title => 'Always wear a proper helmet';

  @override
  String get usage_tips_2_body =>
      'Safety first — a well-fitted helmet also seats your headset closer to your ears for clearer audio on the move.';

  @override
  String get usage_tips_3_title => 'Your mic is hands-free by default';

  @override
  String get usage_tips_3_body =>
      'Voice sensitivity starts wide open with noise suppression doing the work, so you never have to press anything to talk. Fine-tune both anytime in Settings.';

  @override
  String get usage_tips_dismiss => 'GOT IT';

  @override
  String get usage_tips_next => 'NEXT';

  @override
  String get settings_gear_tooltip => 'Settings';
}
