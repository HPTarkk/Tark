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
  String get app_subtitle => 'WALKIE TALKIE';

  @override
  String get live => 'LIVE';

  @override
  String get offline => 'OFFLINE';

  @override
  String get edit_name => 'EDIT';

  @override
  String get connecting => 'Hooking up...';

  @override
  String get monitoring => 'LISTENING';

  @override
  String get initializing => 'WARMING UP';

  @override
  String get tx_label => 'TALKING';

  @override
  String get rx_label => 'INCOMING';

  @override
  String get music_cast => 'SHARE MUSIC';

  @override
  String get music_cast_hint =>
      'Everyone in the channel hears whatever\'s playing on this phone.';

  @override
  String get music_cast_start => 'START SHARING';

  @override
  String get music_cast_starting => 'STARTING...';

  @override
  String get music_cast_stop => 'STOP';

  @override
  String get music_cast_on_air => 'PLAYING';

  @override
  String get music_cast_mix => 'MUSIC VOLUME';

  @override
  String get music_cast_silent => 'Nothing\'s playing — go put a song on';

  @override
  String get music_cast_stop_hint =>
      'Turn on notification access and Stop will pause your music app too';

  @override
  String get music_cast_stop_enable => 'ENABLE';

  @override
  String get channel_members => 'WHO\'S HERE';

  @override
  String get no_users_on_network => 'Nobody else here yet';

  @override
  String get vox_sensitivity => 'HOW IT HEARS YOU';

  @override
  String get vox_threshold => 'HOW LOUD TO START';

  @override
  String get voice_loud => 'LOUD';

  @override
  String get voice_quiet => 'QUIET';

  @override
  String get level_label => 'YOUR VOICE';

  @override
  String get level_active => 'SENDING';

  @override
  String get level_silent => 'QUIET';

  @override
  String get user_idle => 'QUIET';

  @override
  String get set_name_title => 'What should we call you?';

  @override
  String get name_hint => 'Type your name';

  @override
  String get cancel => 'NEVER MIND';

  @override
  String get save => 'SAVE';

  @override
  String get mic_permission_denied =>
      'Tarkk can\'t hear you. Switch the mic on in Settings.';

  @override
  String get join_channel => 'JOIN CHANNEL';

  @override
  String get leave_channel => 'LEAVE CHANNEL';

  @override
  String get no_network => 'Can\'t find a network';

  @override
  String get leave_channel_confirm_title => 'Heading out?';

  @override
  String get leave_channel_confirm_message =>
      'You\'ll be cut off from everyone else in this channel.';

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
      'Your guest points their camera at this code — the join page pops open in their browser.';

  @override
  String get guest_step_answer =>
      'A reply code shows up on their screen. Scan it with the button below, or paste it if they sent it over instead.';

  @override
  String get guest_scan_answer => 'SCAN REPLY CODE';

  @override
  String get guest_link_failed =>
      'That didn\'t work. Make a new invite and give it another go.';

  @override
  String get guest_no_server_badge => 'NO MIDDLEMAN';

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
      'Works over the internet on most networks. A few really locked-down office or school networks might block it.';

  @override
  String get guest_web_scan_title => 'Scan to join';

  @override
  String get guest_web_scan_text =>
      'Open this page by scanning the invite QR code, or tapping the invite link, from the host\'s phone.';

  @override
  String get guest_web_failed_title => 'That didn\'t work';

  @override
  String get guest_web_failed_text =>
      'Couldn\'t get you connected. Ask the host for a new invite and give it another go.';

  @override
  String get guest_web_reply_chip => 'STEP 2 — REPLY CODE';

  @override
  String get guest_web_reply_title => 'Show this code to the host phone';

  @override
  String get guest_web_reply_hint =>
      'On the host: tap \"SCAN REPLY CODE\" and point the camera over here.';

  @override
  String get guest_web_reply_copy => 'COPY CODE';

  @override
  String get guest_web_reply_copied => 'Reply code copied';

  @override
  String get guest_web_connected => 'You\'re in!';

  @override
  String get guest_web_enable_audio =>
      'Tap below to switch on your mic and speaker.';

  @override
  String get guest_web_start_audio => 'START AUDIO';

  @override
  String get guest_web_mute => 'MUTE';

  @override
  String get guest_web_unmute => 'UNMUTE';

  @override
  String get guest_web_talking => 'Talking...';

  @override
  String get guest_web_on_air => 'Everyone can hear you';

  @override
  String get guest_web_standby => 'Waiting';

  @override
  String get guest_web_link_lost => 'CONNECTION LOST';

  @override
  String get guest_web_link_lost_text => 'Lost you — trying again...';

  @override
  String get guest_web_left_title => 'You left the channel';

  @override
  String get guest_web_left_text =>
      'You\'re disconnected. Want back in? Ask the host for a fresh invite and scan it again.';

  @override
  String get bt_start_session => 'START THE LINK';

  @override
  String get bt_role_host_desc =>
      'Let the other phone find this one and hop on';

  @override
  String get bt_find_nearby => 'FIND NEARBY';

  @override
  String get bt_role_join_desc =>
      'Have a look around and jump on a phone that\'s waiting';

  @override
  String get bt_visible_as => 'OTHERS SEE YOU AS';

  @override
  String get bt_last_session => 'LAST CONNECTION';

  @override
  String get bt_reconnect => 'CONNECT AGAIN';

  @override
  String get bt_link_reconnecting =>
      'Lost the Bluetooth link — trying again...';

  @override
  String get bt_link_down => 'Bluetooth connection lost';

  @override
  String get bt_waiting_for_peer => 'Waiting on the other phone...';

  @override
  String get bt_scanning => 'Having a look...';

  @override
  String get bt_no_devices_found => 'Nothing nearby';

  @override
  String get bt_connecting => 'Hooking up...';

  @override
  String get bt_connected => 'You\'re in!';

  @override
  String get bt_permission_denied =>
      'Tarkk can\'t use Bluetooth. Switch it on in Settings.';

  @override
  String get bt_not_supported_platform =>
      'Bluetooth doesn\'t work on this phone yet — use WiFi instead.';

  @override
  String get open_settings => 'OPEN SETTINGS';

  @override
  String get retry => 'TRY AGAIN';

  @override
  String get permissions_title => 'Permissions';

  @override
  String get permission_granted => 'All good';

  @override
  String get permission_grant => 'ALLOW';

  @override
  String get permission_mic_title => 'Microphone';

  @override
  String get permission_mic_desc =>
      'So the app can pick up your voice and send it along.';

  @override
  String get permission_bluetooth_title => 'Bluetooth';

  @override
  String get permission_bluetooth_desc =>
      'So the app can find a phone nearby and hook up with it over Bluetooth.';

  @override
  String get permission_bt_scan_title => 'Look for phones';

  @override
  String get permission_bt_scan_desc =>
      'Spots phones nearby that you can hop onto.';

  @override
  String get permission_bt_connect_title => 'Connect';

  @override
  String get permission_bt_connect_desc =>
      'Hooks up with the other phone and passes voices back and forth.';

  @override
  String get permission_bt_advertise_title => 'Be findable';

  @override
  String get permission_bt_advertise_desc =>
      'Lets the other phone spot yours when you\'re the one starting things off.';

  @override
  String get permission_hotspot_title => 'Location & nearby Wi-Fi';

  @override
  String get permission_hotspot_desc =>
      'Android wants this before your phone can make a hotspot for others to join.';

  @override
  String get permission_battery_title => 'Keep running with the screen off';

  @override
  String get permission_battery_desc =>
      'Keeps the channel going when the screen goes dark — without it, your phone might quietly shut the app down mid-ride.';

  @override
  String get bt_connection_failed => 'That didn\'t work';

  @override
  String get bt_back => 'BACK';

  @override
  String get theme_dark => 'DARK';

  @override
  String get theme_light => 'LIGHT';

  @override
  String get noise_filter => 'BACKGROUND NOISE';

  @override
  String get noise_filter_off => 'OFF';

  @override
  String get noise_filter_weak => 'LOW';

  @override
  String get noise_filter_strong => 'HIGH';

  @override
  String get settings_advanced_row => 'Advanced settings';

  @override
  String get settings_advanced_row_desc =>
      'Extra bits to play with — most people never need these';

  @override
  String get settings_advanced_title => 'Advanced settings';

  @override
  String get noise_cleaner_section => 'NOISE CLEANER';

  @override
  String get noise_cleaner_intro =>
      'Pick how the app cleans up background sounds while you talk.';

  @override
  String get noise_cleaner_simple_title => 'Simple cleaner';

  @override
  String get noise_cleaner_simple_desc =>
      'Quiets steady sounds, like a fan or a car engine.';

  @override
  String get noise_cleaner_simple_downside =>
      'Wind and street sounds can sneak through.';

  @override
  String get noise_cleaner_smart_title => 'Smart cleaner';

  @override
  String get noise_cleaner_smart_desc =>
      'It\'s learned what noise sounds like, so it clears out wind and street sounds too.';

  @override
  String get noise_cleaner_smart_downside => 'Eats more battery.';

  @override
  String get noise_cleaner_both_title => 'Both together';

  @override
  String get noise_cleaner_both_desc =>
      'Runs both cleaners one after the other for the quietest sound.';

  @override
  String get noise_cleaner_both_downside =>
      'Eats the most battery, and your voice might sound a bit thin.';

  @override
  String get noise_cleaner_downside_label => 'The catch';

  @override
  String get noise_cleaner_unavailable =>
      'The smart cleaner isn\'t ready on this phone yet, so you get the simple one.';

  @override
  String get sfx_feedback => 'BEEPS & CLICKS';

  @override
  String get link_reconnecting => 'Lost you — trying again...';

  @override
  String link_reconnecting_in(Object seconds) {
    return 'Trying again in ${seconds}s';
  }

  @override
  String get link_down => 'Connection lost';

  @override
  String get transport_hotspot => 'HOTSPOT';

  @override
  String get hotspot_title => 'Hotspot setup';

  @override
  String get wifi_only_instructions =>
      'Already on the same Wi-Fi? Nothing to set up — just hop in.';

  @override
  String get wifi_only_step_same_network =>
      'Make sure both phones are on the same Wi-Fi.';

  @override
  String get hotspot_not_supported =>
      'Hotspot only works on Android and iPhone.';

  @override
  String get hotspot_role_title => 'Which end is this phone?';

  @override
  String get hotspot_role_hint =>
      'One phone makes the network, the other scans its code.';

  @override
  String get hotspot_role_host => 'CREATE THE HOTSPOT';

  @override
  String get hotspot_role_host_desc =>
      'This phone makes the network and shows a code for the other one to scan.';

  @override
  String get hotspot_role_join => 'JOIN A HOTSPOT';

  @override
  String get hotspot_role_join_desc =>
      'Scan the code on the phone that made the network.';

  @override
  String get hotspot_host_badge => 'TARKK HOTSPOT • ON AIR';

  @override
  String get hotspot_show_credentials =>
      'Can\'t scan it? Show the network details';

  @override
  String get hotspot_hide_credentials => 'Hide the details';

  @override
  String get hotspot_network_note =>
      'Android picks this name itself and no app can change it. This is your Tarkk hotspot — and the other phone never has to read it, scanning the code is enough.';

  @override
  String get hotspot_creating => 'Making the hotspot...';

  @override
  String get hotspot_waiting => 'Waiting on the other phone...';

  @override
  String get hotspot_step_scan =>
      'On the other phone, open Tarkk → Hotspot → Join a hotspot, then scan this code.';

  @override
  String get hotspot_step_join_channel =>
      'Then it hops into the channel, and your voices travel over this Wi-Fi.';

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
      'Couldn\'t make the hotspot. Try again, or let the other phone do it instead.';

  @override
  String get hotspot_error_tethering =>
      'Your phone\'s own hotspot is already on. Switch it off and try again.';

  @override
  String get hotspot_error_location =>
      'Android wants Location switched on before it\'ll make a hotspot.';

  @override
  String get hotspot_error_permission =>
      'Tarkk needs to see nearby Wi-Fi before it can make a hotspot. Allow it and try again.';

  @override
  String get hotspot_error_no_channel =>
      'No free space on Wi-Fi right now. Drop off the Wi-Fi network you\'re on, then try again.';

  @override
  String get hotspot_error_incompatible =>
      'Wi-Fi is busy with something else. Flip Wi-Fi off and on, then try again.';

  @override
  String get hotspot_error_unsupported =>
      'This phone can\'t make its own hotspot — you need Android 8 or newer.';

  @override
  String get hotspot_open_settings => 'OPEN SETTINGS';

  @override
  String get hotspot_try_joining => 'JOIN THE OTHER PHONE INSTEAD';

  @override
  String get hotspot_join_instructions =>
      'Ask the other phone to open Tarkk → Hotspot → Create the hotspot, then scan its code here.';

  @override
  String get hotspot_scan_host => 'SCAN HOST CODE';

  @override
  String get hotspot_scan_hint =>
      'Point the camera at the code on the other phone.';

  @override
  String get hotspot_scan_camera_denied =>
      'Tarkk needs the camera to read the host\'s code.';

  @override
  String get hotspot_scan_camera_failed =>
      'The camera wouldn\'t start. Close whatever else is using it and try again.';

  @override
  String get hotspot_scan_searching => 'LOOKING FOR THE CODE';

  @override
  String get hotspot_scan_locked => 'CODE FOUND';

  @override
  String get hotspot_scan_again => 'SCAN AGAIN';

  @override
  String get hotspot_joining => 'Joining the network...';

  @override
  String get hotspot_joined => 'You\'re on the network';

  @override
  String hotspot_joined_network(Object network) {
    return 'You\'re on $network';
  }

  @override
  String get hotspot_join_waiting => 'Hop into the channel to start talking.';

  @override
  String get hotspot_link_lost =>
      'The hotspot vanished. Join again to get back.';

  @override
  String get hotspot_rejoin => 'JOIN AGAIN';

  @override
  String get hotspot_manual_join_title => 'Join this network yourself';

  @override
  String get hotspot_manual_join_hint =>
      'Open Settings › Wi-Fi, pick this network, then come back and tap the button below.';

  @override
  String get hotspot_manual_joined => 'I\'VE JOINED';

  @override
  String get hotspot_invalid_qr =>
      'That\'s not a Wi-Fi code. Scan the one showing on the host phone.';

  @override
  String get bt_ios_hint =>
      'Bluetooth between an iPhone and an Android drops a lot. For something steadier between them, use Hotspot.';

  @override
  String get bt_ble_unavailable =>
      'This phone can\'t make itself findable over Bluetooth, so iPhones won\'t see it here.';

  @override
  String get bt_use_wifi_bridge => 'USE WI-FI INSTEAD';

  @override
  String get background_title => 'Keep talking with the screen off';

  @override
  String get background_desc =>
      'When you\'re riding, let the app keep going after the screen goes dark so voices keep coming through. Without it, your phone might drop the Wi-Fi and go quiet.';

  @override
  String get background_allow => 'KEEP IT RUNNING';

  @override
  String get background_autostart => 'START ON ITS OWN';

  @override
  String get background_dismiss => 'NOT NOW';

  @override
  String get music_cast_stalled =>
      'This phone won\'t share music during a channel call. Music sharing stopped.';

  @override
  String get settings_title => 'Settings';

  @override
  String get settings_section_identity => 'ABOUT YOU';

  @override
  String get settings_section_voice => 'VOICE & SOUND';

  @override
  String get settings_section_sound => 'BEEPS & ALERTS';

  @override
  String get settings_section_appearance => 'APPEARANCE';

  @override
  String get settings_section_connection => 'CONNECTION';

  @override
  String get settings_section_startup => 'WHEN THE APP OPENS';

  @override
  String get settings_applies_live => 'Kicks in on your channel right away';

  @override
  String get settings_applies_next_session =>
      'Kicks in next time you join a channel';

  @override
  String get settings_quick_access => 'Quick access';

  @override
  String get settings_quick_access_desc =>
      'Skip this screen and drop straight back into your last channel';

  @override
  String get settings_delay => 'SOUND DELAY';

  @override
  String get settings_delay_desc =>
      'The app waits a beat before playing what it hears. Waiting longer smooths out choppy voices — but you hear your friends a little later.';

  @override
  String get settings_delay_low_hint => 'HEAR IT SOONER';

  @override
  String get settings_delay_high_hint => 'SMOOTHER SOUND';

  @override
  String get settings_restore_defaults => 'RESET TO NORMAL';

  @override
  String get settings_restore_defaults_done =>
      'Voice settings are back to normal';

  @override
  String get settings_auto_reconnect => 'Connect again by itself';

  @override
  String get settings_auto_reconnect_desc =>
      'Hops back on by itself when the connection drops, and picks up your last Bluetooth phone when you\'re back';

  @override
  String get settings_permissions_row => 'Permissions';

  @override
  String get settings_permissions_row_desc =>
      'See and change what the app can get at';

  @override
  String get settings_wifi_hotspot_row => 'WiFi / Hotspot setup';

  @override
  String get settings_wifi_hotspot_row_desc =>
      'Make a hotspot, or see how to join over WiFi';

  @override
  String get settings_skip_splash => 'Skip splash screen';

  @override
  String get settings_skip_splash_desc => 'Jump straight into the app';

  @override
  String get usage_tips_title => 'Get the most out of TarkK';

  @override
  String get usage_tips_1_title => 'Wear a headset that blocks out noise';

  @override
  String get usage_tips_1_body =>
      'A headset that cuts out noise makes it way easier to hear the channel over wind and engine sound — and your hands stay free while you ride.';

  @override
  String get usage_tips_2_title => 'Always wear a proper helmet';

  @override
  String get usage_tips_2_body =>
      'Safety first — and a helmet that fits right holds your headset closer to your ears, so voices come through clearer on the move.';

  @override
  String get usage_tips_3_title => 'You never have to press anything to talk';

  @override
  String get usage_tips_3_body =>
      'The mic listens the whole time and the app cleans up the noise, so just talk. Tweak both whenever you like in Settings.';

  @override
  String get usage_tips_dismiss => 'GOT IT';

  @override
  String get usage_tips_next => 'NEXT';

  @override
  String get settings_gear_tooltip => 'Settings';

  @override
  String get onboarding_welcome_title => 'A walkie-talkie on your own network';

  @override
  String get onboarding_welcome_sub =>
      'Talk to phones nearby with no internet — straight across, fast and private.';

  @override
  String get onboarding_info_lan => 'Works over shared WiFi or a hotspot';

  @override
  String get onboarding_info_private =>
      'No accounts, no middleman — your voice never leaves your own network';

  @override
  String get onboarding_info_vox =>
      'No button to press — just talk, and everyone hears you';

  @override
  String get onboarding_skip => 'SKIP';

  @override
  String get onboarding_begin => 'START SETUP';

  @override
  String get onboarding_continue => 'CONTINUE';

  @override
  String get onboarding_finish => 'LET\'S GO';

  @override
  String get onboarding_callsign_title => 'Pick your radio name';

  @override
  String get onboarding_callsign_help =>
      'This is how everyone in the channel sees you.';

  @override
  String get onboarding_mode_title => 'How will you connect?';

  @override
  String get onboarding_mode_help => 'You can switch this anytime in Settings.';

  @override
  String get onboarding_mode_wifi_desc =>
      'Everyone on the same WiFi — clearest sound, longest reach';

  @override
  String get onboarding_mode_bluetooth_desc =>
      'Two phones straight to each other, no network at all';

  @override
  String get onboarding_mode_guest_desc =>
      'Guests hop in from a browser by scanning a QR code';

  @override
  String get onboarding_ready_title => 'You\'re all set';

  @override
  String get onboarding_ready_sub =>
      'Here\'s your radio card — this is how the channel sees you.';

  @override
  String get onboarding_tip_vox =>
      'No button needed — just talk and everyone hears you.';

  @override
  String get onboarding_tip_settings =>
      'Your name, how you connect, and your mic all live in Settings.';

  @override
  String get onboarding_tune_title => 'Make it yours';

  @override
  String get onboarding_tune_sub =>
      'Pick a language and a look — you can switch both in Settings whenever.';

  @override
  String get onboarding_language_label => 'LANGUAGE';

  @override
  String get onboarding_theme_label => 'LOOK';

  @override
  String get onboarding_signal => 'SIGNAL';

  @override
  String get onboarding_stamp_ready => 'READY';

  @override
  String get onboarding_explore => 'Look around first';

  @override
  String get onboarding_callsign_pool =>
      'Falcon,Viper,Echo,Maverick,Storm,Ghost,Ranger,Nomad';

  @override
  String get settings_replay_intro => 'Replay intro';

  @override
  String get settings_replay_intro_desc =>
      'Run through the welcome and setup steps again';
}
