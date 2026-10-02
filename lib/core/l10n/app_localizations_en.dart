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
  String get connecting => 'Hooking up…';

  @override
  String get monitoring => 'LISTENING';

  @override
  String get initializing => 'WARMING UP';

  @override
  String get tx_label => 'TALKING';

  @override
  String get rx_label => 'INCOMING';

  @override
  String get mic_on_air => 'ON AIR';

  @override
  String get mic_section => 'YOUR MIC';

  @override
  String get mic_live_title => 'MIC LIVE';

  @override
  String get mic_live_label => 'Everyone hears you';

  @override
  String get mic_muted_title => 'MUTED';

  @override
  String get mic_muted_label => 'No one hears you';

  @override
  String get mic_action_mute => 'MUTE';

  @override
  String get mic_action_unmute => 'UNMUTE';

  @override
  String get music_cast => 'SHARE MUSIC';

  @override
  String get music_cast_hint =>
      'Everyone in the channel hears whatever\'s playing on this phone.';

  @override
  String get music_cast_start => 'START SHARING';

  @override
  String get music_cast_starting => 'STARTING…';

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
  String get vox_margin_hint =>
      'Measured against the room, so one setting works parked and at speed';

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
  String get connect_via_hotspot => 'CONNECT VIA HOTSPOT';

  @override
  String get channel_create => 'START A CHANNEL';

  @override
  String get channel_join => 'JOIN A CHANNEL';

  @override
  String get channel_via_shared_network => 'on this Wi-Fi network';

  @override
  String get channel_via_own_hotspot => 'this phone makes the network';

  @override
  String get channel_via_scan_code => 'scan the other phone\'s code';

  @override
  String get channel_via_bluetooth => 'over Bluetooth, no network needed';

  @override
  String get channel_via_guest => 'invite a browser guest';

  @override
  String get channel_via_no_network => 'no network to use yet';

  @override
  String get channel_different_network => 'Not on the same network?';

  @override
  String get channel_same_wifi => 'On the same Wi-Fi?';

  @override
  String get channel_pinned_note => 'picked by hand';

  @override
  String get transport_automatic => 'AUTOMATIC';

  @override
  String get channel_code_label => 'CHANNEL CODE';

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
  String get transport_wifi => 'WI-FI';

  @override
  String get transport_wifi_hotspot => 'WI-FI / HOTSPOT';

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
      'On the host: tap “SCAN REPLY CODE” and point the camera over here.';

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
  String get guest_web_talking => 'Talking…';

  @override
  String get guest_web_on_air => 'Everyone can hear you';

  @override
  String get guest_web_standby => 'Waiting';

  @override
  String get guest_web_link_lost => 'CONNECTION LOST';

  @override
  String get guest_web_link_lost_text => 'Lost you — trying again…';

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
  String get bt_link_reconnecting => 'Lost the Bluetooth link — trying again…';

  @override
  String get bt_link_down => 'Bluetooth connection lost';

  @override
  String get bt_waiting_for_peer => 'Waiting on the other phone…';

  @override
  String get bt_scanning => 'Having a look…';

  @override
  String get bt_no_devices_found => 'Nothing nearby';

  @override
  String get bt_location_off =>
      'Android won\'t let this phone look for nearby phones while Location is off. Switch Location on to search.';

  @override
  String get bt_unnamed_device => 'Unnamed device';

  @override
  String get default_user_name => 'Buddy';

  @override
  String get landing_ready => 'Ready to talk';

  @override
  String get bt_connecting => 'Hooking up…';

  @override
  String get bt_connected => 'You\'re in!';

  @override
  String get bt_permission_denied =>
      'Tarkk can\'t use Bluetooth. Switch it on in Settings.';

  @override
  String get bt_not_supported_platform =>
      'Bluetooth doesn\'t work on this phone yet — use Wi-Fi instead.';

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
  String get onb_theme_day => 'DAY';

  @override
  String get onb_theme_night => 'NIGHT';

  @override
  String get noise_filter => 'BACKGROUND NOISE';

  @override
  String get noise_filter_off => 'OFF';

  @override
  String get noise_filter_weak => 'LOW';

  @override
  String get noise_filter_strong => 'HIGH';

  @override
  String get noise_filter_cleaner_off =>
      'Off while no cleaner is picked below.';

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
  String get noise_cleaner_off_title => 'No cleaner';

  @override
  String get noise_cleaner_off_desc =>
      'Sends your voice exactly as the mic hears it. Nothing is removed, so nothing of your voice is lost either.';

  @override
  String get noise_cleaner_off_downside =>
      'Everything around you goes through too — wind, engine, traffic.';

  @override
  String get noise_cleaner_downside_label => 'The catch';

  @override
  String get noise_cleaner_unavailable =>
      'The smart cleaner isn\'t ready on this phone yet, so you get the simple one.';

  @override
  String get sfx_feedback => 'BEEPS & CLICKS';

  @override
  String get smart_music_ducking => 'Smart music ducking';

  @override
  String get smart_music_ducking_desc =>
      'Automatically lowers shared music while someone is talking';

  @override
  String get link_reconnecting => 'Lost you — trying again…';

  @override
  String link_reconnecting_in(Object seconds) {
    return 'Trying again in ${seconds}s';
  }

  @override
  String get link_down => 'Connection lost';

  @override
  String peer_left_channel(Object name) {
    return '$name left the channel';
  }

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
  String get hotspot_creating => 'Making the hotspot…';

  @override
  String get hotspot_wifi_note_title =>
      'Turn Wi-Fi off for a better connection';

  @override
  String get hotspot_wifi_note_title_dropped =>
      'Turn Wi-Fi off so this stops happening';

  @override
  String get hotspot_wifi_note_body =>
      'Your phone can\'t do Wi-Fi and a hotspot properly at the same time. With Wi-Fi off, the connection to your friends is stronger and won\'t drop.';

  @override
  String get hotspot_wifi_note_body_dropped =>
      'Your hotspot just went down, and Wi-Fi being on is why. Turn it off and the connection stays put.';

  @override
  String get hotspot_wifi_note_action => 'TURN WI-FI OFF';

  @override
  String get hotspot_wifi_note_dismiss => 'NOT NOW';

  @override
  String get hotspot_wifi_note_reassure =>
      'You\'ll still hear everyone — the channel doesn\'t need Wi-Fi.';

  @override
  String get hotspot_wifi_off_page_title =>
      'Turn off Wi-Fi for a steadier connection';

  @override
  String get hotspot_wifi_off_page_body =>
      'This phone is running the hotspot. While Wi-Fi is on, Android can jump back to a saved network and quietly switch the hotspot off.';

  @override
  String get hotspot_wifi_off_page_point_steady =>
      'The hotspot stays on the whole time';

  @override
  String get hotspot_wifi_off_page_point_clear =>
      'Voices come through clearer, with fewer drops';

  @override
  String get hotspot_wifi_off_page_point_channel =>
      'Everyone still hears you. Tarkk doesn\'t need Wi-Fi here.';

  @override
  String get hotspot_wifi_off_page_status_on => 'Wi-Fi is on';

  @override
  String get hotspot_wifi_off_page_status_off => 'Wi-Fi is off';

  @override
  String get hotspot_wifi_off_page_action => 'Turn Wi-Fi off';

  @override
  String get hotspot_wifi_off_page_done => 'All set';

  @override
  String get hotspot_wifi_off_page_skip => 'Continue anyway';

  @override
  String get hotspot_waiting => 'Waiting on the other phone…';

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
  String get hotspot_copied => 'Copied';

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
  String get hotspot_joining =>
      'Joining the network… Say yes to Android\'s “connect to this network” prompt — on some phones it turns up in your notifications rather than on screen.';

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
  String get hotspot_manual_not_pinned =>
      'This phone isn\'t on the host\'s network yet. Pick it in Settings › Wi-Fi, then tap again.';

  @override
  String get hotspot_invalid_qr =>
      'That\'s not a Wi-Fi code. Scan the one showing on the host phone.';

  @override
  String get hotspot_wifi_off =>
      'Wi-Fi is off on this phone, so it can\'t join the hotspot. Switch it on and try again.';

  @override
  String get hotspot_enable_wifi => 'TURN WI-FI ON';

  @override
  String get hotspot_location_off =>
      'Android won\'t let this phone look for Wi-Fi networks while Location is off, so it can\'t find the hotspot. Switch Location on and try again.';

  @override
  String get hotspot_enable_location => 'TURN LOCATION ON';

  @override
  String get bt_ios_hint =>
      'Bluetooth between an iPhone and an Android drops a lot. For something steadier between them, use Hotspot.';

  @override
  String get bt_ble_unavailable =>
      'This phone can\'t make itself findable over Bluetooth, so iPhones won\'t see it here.';

  @override
  String get bt_use_wifi_bridge => 'USE WI-FI INSTEAD';

  @override
  String get bt_not_discoverable =>
      'Other phones can\'t spot this one right now — the findable window ran out.';

  @override
  String get bt_make_discoverable => 'LET THEM FIND ME';

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
  String get music_cast_blocked =>
      'This phone won\'t share music during a channel call. Your song is playing, but peers can\'t hear it.';

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
  String get settings_section_transport => 'HOW PHONES LINK UP';

  @override
  String get settings_transport_desc =>
      'Tarkk picks the link that suits wherever you are. Pin one only if you have a reason to.';

  @override
  String get settings_section_startup => 'WHEN THE APP OPENS';

  @override
  String get settings_applies_live => 'Kicks in on your channel right away';

  @override
  String get settings_applies_next_session =>
      'Kicks in next time you join a channel';

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
  String get settings_section_hd_audio => 'HD AUDIO QUALITY';

  @override
  String get hd_voice_label => 'HD Voice';

  @override
  String get hd_voice_desc =>
      'Clearer, richer voice when everyone on the channel supports it. Uses a bit more data, and falls back automatically for anyone who doesn\'t.';

  @override
  String get hd_music_label => 'HD Shared Music';

  @override
  String get hd_music_desc =>
      'Higher-quality stereo sound when you share music with the channel.';

  @override
  String get settings_riding_section => 'RIDING MODE';

  @override
  String get settings_riding_label => 'Set up for the road';

  @override
  String get settings_riding_desc =>
      'One switch that gets your voice through wind and engine noise: the mic waits for you to actually talk instead of sending everything it hears, the noise cleaner runs at a level that keeps words crisp, the app holds a bit more sound in reserve so a connection on the move doesn\'t chop, and everyone else comes through a touch louder.';

  @override
  String get settings_riding_kept =>
      'Your own settings stay put — they come back the moment you switch it off.';

  @override
  String get settings_riding_overridden =>
      'Riding mode is choosing this for you. Switch it off to set it yourself.';

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
  String get settings_wifi_hotspot_row => 'Wi-Fi / Hotspot setup';

  @override
  String get settings_wifi_hotspot_row_desc =>
      'Make a hotspot, or see how to join over Wi-Fi';

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
  String get usage_tips_4_title => 'Keep the channel on your home screen';

  @override
  String get usage_tips_4_body =>
      'Add the Tarkk widget and you can see who\'s on air at a glance, then tap once to jump straight in — no digging through the app. Add it any time from Settings.';

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
  String get onboarding_info_lan => 'Works over shared Wi-Fi or a hotspot';

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
  String get onboarding_avatar_title => 'Pick your face';

  @override
  String get onboarding_avatar_help =>
      'Everyone in the channel sees it next to your name. You can change it any time on your profile.';

  @override
  String get profile_title => 'PROFILE';

  @override
  String get profile_name_label => 'RADIO NAME';

  @override
  String get profile_avatar_label => 'YOUR FACE';

  @override
  String get onboarding_mode_title => 'How will you connect?';

  @override
  String get onboarding_mode_help =>
      'Leave it automatic and Tarkk works this out each time. You can pin one later in Advanced settings.';

  @override
  String get onboarding_mode_auto_desc =>
      'Tarkk picks — same Wi-Fi, its own hotspot, or Bluetooth';

  @override
  String get onboarding_mode_wifi_desc =>
      'Everyone on the same Wi-Fi — clearest sound, longest reach';

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

  @override
  String get widget_status_setup => 'Finish setup to go live';

  @override
  String get widget_status_idle => 'Tap to go live';

  @override
  String widget_status_receiving(Object name) {
    return '$name is talking';
  }

  @override
  String get widget_action_go => 'GO LIVE';

  @override
  String get widget_action_setup => 'SET UP';

  @override
  String get widget_action_open => 'OPEN';

  @override
  String get widget_peers_alone => 'Nobody else here yet';

  @override
  String widget_peers(Object count) {
    return '$count on channel';
  }

  @override
  String get widget_end => 'END';

  @override
  String get settings_add_widget => 'Add the channel widget';

  @override
  String get settings_widget_hint =>
      'Put a dial on your home screen — see who\'s on air and jump in with one tap.';

  @override
  String get role_host => 'Base Station';

  @override
  String get role_joiner => 'Field Unit';

  @override
  String get role_peer => 'Open Air';

  @override
  String get help_button => 'SOMETHING WRONG?';

  @override
  String get help_title => 'What\'s going on?';

  @override
  String get help_all_good =>
      'Everything checks out. If people still can\'t hear you, ask them to leave the channel and come back in.';

  @override
  String get help_found_problems => 'Sort out whatever\'s red below.';

  @override
  String get check_mic => 'Microphone';

  @override
  String get check_mic_ok => 'Working';

  @override
  String get check_mic_denied => 'Tarkk isn\'t allowed to use it';

  @override
  String get check_mic_silent => 'Allowed, but no sound is coming through';

  @override
  String get check_network => 'Network';

  @override
  String get check_network_ok => 'Connected';

  @override
  String get check_network_none => 'This phone isn\'t on a Wi-Fi network';

  @override
  String get check_network_bt => 'Bluetooth link';

  @override
  String get check_network_bt_ok => 'Paired and open';

  @override
  String get check_people => 'Who\'s in range';

  @override
  String check_people_ok(Object count) {
    return '$count here with you';
  }

  @override
  String get check_people_alone => 'Nobody else has joined yet';

  @override
  String get check_link => 'Connection';

  @override
  String get check_link_ok => 'Steady';

  @override
  String get check_link_retrying => 'Dropped — getting it back';

  @override
  String get check_link_down => 'Lost';

  @override
  String get issue_mic_denied_title => 'Nobody can hear you';

  @override
  String get issue_mic_denied_body =>
      'Tarkk needs permission to use your microphone. Switch it on and you\'re straight back on air.';

  @override
  String get issue_mic_silent_title => 'Others can\'t hear you';

  @override
  String get issue_mic_silent_body =>
      'Tap Fix sound. If it happens again, reconnect your handsfree or close other apps that use sound.';

  @override
  String get issue_no_network_title => 'You\'re not on a network';

  @override
  String get issue_no_network_body =>
      'Your voice can\'t go anywhere until this phone joins a Wi-Fi network. Everyone in the channel has to be on the same one.';

  @override
  String get issue_start_failed_title => 'The channel didn\'t open';

  @override
  String get issue_start_failed_body =>
      'Something went wrong while setting up. Give it another go.';

  @override
  String get issue_alone_title => 'You\'re on your own in here';

  @override
  String get issue_alone_body =>
      'Nobody else has turned up yet. Check the other phone is on the same network and has joined the channel.';

  @override
  String get fix_allow_mic => 'ALLOW MIC';

  @override
  String get fix_wifi_settings => 'WI-FI SETTINGS';

  @override
  String get fix_restart_mic => 'RESTART MIC';

  @override
  String get fix_sound => 'FIX SOUND';

  @override
  String get fix_reconnect => 'RECONNECT';

  @override
  String get retry_still_trying => 'Still trying…';

  @override
  String get bt_still_trying => 'Still trying to reach them…';

  @override
  String get hotspot_still_trying => 'Still setting it up…';

  @override
  String get premium_badge => 'PREMIUM';

  @override
  String get paywall_title => 'GO PREMIUM';

  @override
  String get paywall_locked_wifi => 'Wi-Fi, Hotspot and Guest are premium';

  @override
  String get paywall_locked_mute => 'Muting yourself is premium';

  @override
  String get paywall_locked_music => 'Sharing music is premium';

  @override
  String get paywall_free_note => 'Bluetooth stays free, always';

  @override
  String get paywall_unavailable =>
      'Purchases aren\'t available in this build yet';

  @override
  String get paywall_restore => 'RESTORE PURCHASE';

  @override
  String get paywall_restored => 'Premium restored';

  @override
  String get paywall_restore_none => 'Nothing to restore';

  @override
  String get paywall_close => 'NOT NOW';

  @override
  String get paywall_plan_1m => '1 MONTH';

  @override
  String get paywall_plan_12m => '1 YEAR';

  @override
  String get sub_checking => 'Checking your subscription…';

  @override
  String get sub_granted => 'You\'re all set';

  @override
  String get sub_try_again => 'TRY AGAIN';

  @override
  String get sub_not_now => 'NOT NOW';

  @override
  String get sub_free_meanwhile =>
      'Bluetooth keeps working as usual in the meantime.';

  @override
  String get sub_support_prompt => 'Something not right? We\'re glad to help:';

  @override
  String get sub_email_subject => 'Tark subscription';

  @override
  String get sub_nodata_title => 'Let\'s check your subscription';

  @override
  String get sub_nodata_body_offline =>
      'To unlock this, we need to check your subscription once, and this phone doesn\'t seem to be online right now. Connect to the internet and try again.';

  @override
  String get sub_nodata_body_trouble =>
      'To unlock this, we need to check your subscription once, and we couldn\'t reach our servers just now. That\'s on our side, not yours. Please try again in a little while.';

  @override
  String get sub_expired_title => 'Time for a quick check';

  @override
  String sub_expired_body_offline(String date) {
    return 'According to the latest information we have, your subscription ended on $date. We couldn\'t get anything newer because this phone doesn\'t seem to be online right now.\n\nIf you\'ve already renewed, or this doesn\'t look right, connect to the internet and try again, or get in touch with us.';
  }

  @override
  String sub_expired_body_trouble(String date) {
    return 'According to the latest information we have, your subscription ended on $date. We couldn\'t reach our servers just now to get anything newer. That\'s on our side, not yours.\n\nIf you\'ve already renewed, or this doesn\'t look right, try again in a little while, or get in touch with us.';
  }

  @override
  String get sub_stale_title => 'A quick check-in';

  @override
  String sub_stale_body_offline(String date) {
    return 'We last confirmed your subscription on $date, and it\'s time for a quick refresh. Connect to the internet for a moment and we\'ll take care of the rest.';
  }

  @override
  String sub_stale_body_trouble(String date) {
    return 'We last confirmed your subscription on $date, and it\'s time for a quick refresh. We couldn\'t reach our servers just now. That\'s on our side, not yours. Please try again in a little while.';
  }

  @override
  String get sub_renew_title => 'Welcome back';

  @override
  String sub_renew_body(String date) {
    return 'Your subscription ended on $date. Renew any time to pick up right where you left off.';
  }

  @override
  String get sub_signin_title => 'Sign in to subscribe';

  @override
  String get sub_signin_body =>
      'A subscription belongs to your account, so it comes with you to a new phone. Sign in first, then pick a plan.';

  @override
  String get sub_owned_title => 'This purchase is on another account';

  @override
  String get sub_owned_body =>
      'This Bazaar purchase is already linked to a different Tark account. Sign in with that account to use it, or write to us and we\'ll sort it out together.';

  @override
  String get settings_section_diagnostics => 'DIAGNOSTICS';

  @override
  String get settings_share_log => 'Share diagnostic log';

  @override
  String settings_share_log_desc(Object size) {
    return 'Send us what the app recorded so we can see what went wrong ($size)';
  }

  @override
  String get settings_clear_log => 'Clear the log';

  @override
  String get settings_clear_log_desc => 'Delete what\'s stored on this phone';

  @override
  String get settings_clear_log_confirm_title => 'Clear the log?';

  @override
  String get settings_clear_log_confirm_message =>
      'Everything this phone recorded goes for good. If you\'re reporting a bug, share it first.';

  @override
  String get settings_clear_log_confirm_action => 'CLEAR';

  @override
  String get settings_log_empty => 'Nothing recorded yet';

  @override
  String get settings_log_share_failed => 'Couldn\'t open the share sheet';

  @override
  String get settings_log_cleared => 'Log cleared';

  @override
  String get settings_log_max_size => 'MAX LOG SIZE';

  @override
  String get settings_log_max_size_desc =>
      'The log never grows past this. When it\'s full, the oldest lines make way for the newest.';

  @override
  String get settings_log_level => 'LOG LEVEL';

  @override
  String get settings_log_level_standard => 'Standard';

  @override
  String get settings_log_level_screens => 'Screens';

  @override
  String get settings_log_level_everything => 'Everything';

  @override
  String get settings_log_level_desc =>
      'Standard keeps the log as it has always been. Screens also records the pages you open and the main buttons you tap. Everything adds every tap and every settings change. It all stays on this phone.';

  @override
  String settings_log_usage(Object max, Object used) {
    return '$used of $max used';
  }

  @override
  String get settings_log_recycling =>
      'Full — the oldest lines are being overwritten';

  @override
  String get check_heard => 'Being heard';

  @override
  String get check_heard_ok => 'Your voice is reaching them';

  @override
  String get check_heard_unheard => 'Nothing you send is arriving — repairing';

  @override
  String get issue_unheard_title => 'They can\'t hear you';

  @override
  String get issue_unheard_body =>
      'You\'re receiving them, but nothing you send is getting through. Repairing the link automatically — if it doesn\'t come back, leave and rejoin the channel.';

  @override
  String get fix_repair_link => 'Repair link';

  @override
  String get fix_invite_someone => 'Invite someone';

  @override
  String get preflight_check_hd_voice => 'HD Voice';

  @override
  String get preflight_hd_voice_ready => 'HD Voice ready';

  @override
  String get preflight_hd_voice_negotiated_hd =>
      'HD Voice — negotiated with your peer';

  @override
  String get preflight_hd_voice_standard =>
      'Standard voice — your peer doesn\'t support HD yet';

  @override
  String get preflight_check_shared_music => 'Shared Music';

  @override
  String get preflight_shared_music_available => 'Available';

  @override
  String get preflight_shared_music_unavailable =>
      'Not supported on this device';

  @override
  String get preflight_check_diagnostics => 'Diagnostics';

  @override
  String get preflight_diagnostics_ok => 'Ready to record support evidence';

  @override
  String get preflight_diagnostics_memory_only =>
      'Recording, but won\'t survive the app closing';

  @override
  String get preflight_diagnostics_disabled => 'Turned off';

  @override
  String get preflight_check_mic => 'Microphone';

  @override
  String get preflight_mic_permission_denied =>
      'Tarkk isn\'t allowed to use it';

  @override
  String get preflight_mic_no_frames =>
      'Started, but no sound is coming through';

  @override
  String get preflight_mic_ok => 'Working';

  @override
  String get preflight_check_headset => 'Headset';

  @override
  String get preflight_route_bluetooth => 'Connected — Bluetooth headset';

  @override
  String get preflight_route_wired => 'Connected — wired headset';

  @override
  String get preflight_route_speaker => 'Playing through the phone speaker';

  @override
  String get preflight_route_unknown => 'Can\'t tell yet';

  @override
  String get preflight_check_connection => 'Connection';

  @override
  String get preflight_transport_blocked => 'No usable network path';

  @override
  String get preflight_transport_not_attempted => 'Not connected yet';

  @override
  String get preflight_transport_ready => 'Connected';

  @override
  String get preflight_transport_degraded => 'Reconnecting';

  @override
  String get preflight_transport_down => 'Not connected';

  @override
  String get preflight_check_peer_reachability => 'Being heard';

  @override
  String get preflight_peer_not_present => 'Nobody\'s joined yet';

  @override
  String get preflight_peer_unconfirmed =>
      'Waiting to hear back that they can hear you';

  @override
  String get preflight_peer_confirmed => 'They can hear you';

  @override
  String get preflight_check_background => 'Background mode';

  @override
  String get preflight_background_ok => 'Ready for the screen to turn off';

  @override
  String get preflight_background_restricted =>
      'Battery settings might stop Tarkk once the screen turns off';

  @override
  String get preflight_background_notification_denied =>
      'Notifications are off — you won\'t see that a session is still running';

  @override
  String get preflight_fix_allow_notifications => 'ALLOW NOTIFICATIONS';

  @override
  String get preflight_title => 'Preflight check';

  @override
  String get preflight_subtitle_checking => 'Checking your setup…';

  @override
  String get preflight_subtitle_ready => 'You\'re all set';

  @override
  String get preflight_subtitle_warning => 'Works, but worth a look';

  @override
  String get preflight_subtitle_blocked => 'A couple things need fixing first';

  @override
  String get preflight_checking => 'Checking…';

  @override
  String get preflight_fix_issues => 'FIX THE ISSUES ABOVE';

  @override
  String get preflight_continue_anyway => 'CONTINUE ANYWAY';

  @override
  String get preflight_enter_channel => 'ENTER CHANNEL';

  @override
  String get lobby_back => 'Back';

  @override
  String get lobby_heading => 'Ready to start';

  @override
  String get lobby_alone_heading => 'Your room is ready';

  @override
  String get lobby_nothing_started =>
      'Your mic stays off until you press Start ride.';

  @override
  String get lobby_connecting_hint =>
      'Keep the phones close. If your phone asks to connect to a network, tap Connect.';

  @override
  String get lobby_invite_people => 'Invite people';

  @override
  String get lobby_alone_no_invite =>
      'Nobody else is in this room yet. A member who can invite has to add people first.';

  @override
  String get room_start_not_linked =>
      'These phones aren\'t linked right now. Connect them to start.';

  @override
  String get room_start_nobody_answered =>
      'Couldn\'t reach anyone in this room. Make sure they\'re nearby with Tarkk open, then try again.';

  @override
  String get room_start_failed =>
      'Couldn\'t connect. Keep the phones close and try again.';

  @override
  String get room_start_wifi_off => 'Wi-Fi is off. Switch it on and try again.';

  @override
  String get room_start_location_off =>
      'Location is off, so this phone can\'t find the others. Switch it on and try again.';

  @override
  String get room_start_connect => 'Connect phones';

  @override
  String get lobby_alone_title => 'You\'re the only one here';

  @override
  String lobby_alone_body(Object room) {
    return 'Nobody else is in “$room” yet. Show them the invite code — one scan puts them in this room, with no internet.';
  }

  @override
  String get lobby_alone_no_right =>
      'Nobody else is here yet. Adding people is up to whoever runs this room.';

  @override
  String get lobby_invite_someone => 'INVITE SOMEONE';

  @override
  String get lobby_invite_more => 'INVITE SOMEONE ELSE';

  @override
  String get lobby_start_ride => 'Start ride';

  @override
  String get lobby_unlinked_heading => 'Not connected yet';

  @override
  String get lobby_unlinked_lead =>
      'This phone has to be on something before the channel can open.';

  @override
  String get lobby_unlinked_title => 'No link yet';

  @override
  String get lobby_unlinked_body =>
      'Tarkk runs over Wi-Fi, a hotspot one of you turns on, or Bluetooth — no internet, no SIM. Right now this phone is on none of them.';

  @override
  String get lobby_unlinked_no_way_out =>
      'This phone is not on any network right now. Turn Wi-Fi on, or bring a hotspot up from the connect screen.';

  @override
  String get lobby_connect => 'GET CONNECTED';

  @override
  String get lobby_assumed_heading => 'One thing first';

  @override
  String get lobby_assumed_lead =>
      'Being on Wi-Fi is not the same as being on their Wi-Fi.';

  @override
  String get lobby_assumed_title => 'Are they on this network?';

  @override
  String get lobby_assumed_body =>
      'This phone is on a network that was already here, and there is no way from this side to tell whether the others are on it too — nor whether it will still be under you in ten minutes. A hotspot one of you turns on works wherever you end up: you show a code, they scan it.';

  @override
  String get lobby_assumed_no_way_out =>
      'This phone is on a network that was already here. Until someone is heard, there is no telling whether the others are on it.';

  @override
  String get lobby_get_on_one_network => 'GET ON ONE NETWORK';

  @override
  String get lobby_already_together =>
      'We\'re already on the same network — start';

  @override
  String get lobby_link_connected => 'CONNECTED';

  @override
  String get lobby_different_network => 'Not on the same network?';

  @override
  String get lobby_caveat_wifi =>
      'The others have to be on this same network. Until someone is heard, there is no way to tell from here whether they are.';

  @override
  String get lobby_caveat_hotspot =>
      'Your hotspot is up, but nobody is on it until they scan your code.';

  @override
  String get lobby_link_wifi => 'On Wi-Fi';

  @override
  String get lobby_link_hotspot => 'Your hotspot is up';

  @override
  String get lobby_link_bluetooth => 'Bluetooth link';

  @override
  String get lobby_link_none => 'No link';

  @override
  String get lobby_start_alone_hint =>
      'Or start now and invite once you are on the air.';

  @override
  String get lobby_you => 'You';

  @override
  String get lobby_unnamed => 'Room member';

  @override
  String get lobby_held_seats_hint =>
      'They have a code but have not scanned it yet.';

  @override
  String lobby_members(Object count) {
    return 'Room members ($count)';
  }

  @override
  String lobby_held_seats(Object count) {
    return 'Waiting to join ($count)';
  }

  @override
  String get rooms_title => 'Saved rooms';

  @override
  String get rooms_back => 'Back';

  @override
  String get rooms_create => 'Create room';

  @override
  String get rooms_rename => 'Rename';

  @override
  String get rooms_save => 'Save';

  @override
  String get rooms_archive => 'Archive';

  @override
  String get rooms_archived => 'Archived';

  @override
  String get rooms_leave => 'Leave room';

  @override
  String get rooms_cancel => 'Cancel';

  @override
  String get rooms_select => 'Select this room';

  @override
  String get rooms_selected => 'Selected';

  @override
  String get rooms_manage => 'Manage room';

  @override
  String get rooms_retry => 'Retry';

  @override
  String get rooms_name_hint => 'Room name';

  @override
  String get rooms_fallback_member_name => 'Rider';

  @override
  String get rooms_empty_title => 'No saved rooms yet';

  @override
  String get rooms_empty_body =>
      'Rooms stay on this phone offline. Creating or selecting one never starts a hotspot or microphone by itself.';

  @override
  String get rooms_load_error =>
      'Saved rooms could not be loaded. Nothing was deleted.';

  @override
  String get rooms_can_invite => 'You can invite';

  @override
  String get rooms_delete => 'Delete room';

  @override
  String get rooms_archived_rooms => 'Archived rooms';

  @override
  String get rooms_new_room => 'New room';

  @override
  String rooms_member_count(Object count) {
    return '$count members';
  }

  @override
  String rooms_pending_seat_one(Object count) {
    return '$count open seat';
  }

  @override
  String rooms_pending_seats_other(Object count) {
    return '$count open seats';
  }

  @override
  String rooms_archive_confirm(Object name) {
    return 'Moves “$name” out of the list with its membership intact. Bring it back from the archive whenever you want.';
  }

  @override
  String rooms_leave_confirm(Object name) {
    return 'Leave “$name”? This removes your membership and is different from ending a live session.';
  }

  @override
  String rooms_room_semantics(String name, String count) {
    return '$name, $count members';
  }

  @override
  String rooms_room_semantics_selected(String name, String count) {
    return '$name, $count members, selected';
  }

  @override
  String get people_title => 'ROOM PEOPLE';

  @override
  String get people_invite_title => 'NEW INVITE';

  @override
  String get people_you => 'You';

  @override
  String get people_waiting => 'Has not arrived yet';

  @override
  String get people_unnamed => 'Unnamed';

  @override
  String get people_revoke => 'Take the invite back';

  @override
  String get people_create_invite => 'CREATE AN INVITE';

  @override
  String get people_done => 'DONE';

  @override
  String get people_copy_invite => 'Copy invite';

  @override
  String get people_copied => 'Copied';

  @override
  String get people_invite_hint =>
      'Have them scan this with Join with QR, close to this phone. They come straight in.';

  @override
  String people_invite_joined(Object name) {
    return '$name joined';
  }

  @override
  String get people_invite_permission =>
      'Sharing an invite needs the Nearby devices permission.';

  @override
  String get people_invite_visible =>
      'Let this phone be visible to nearby devices, so theirs can find it.';

  @override
  String get people_invite_unsupported =>
      'This phone\'s Bluetooth can\'t send an invite. Ask the other person to invite you, then scan their code with Join with QR.';

  @override
  String get people_invite_paused => 'This invite timed out.';

  @override
  String get people_invite_show_again => 'Show again';

  @override
  String get people_held_seats_hint =>
      'These seats were opened by an invite nobody has used yet. They are not counted as members.';

  @override
  String get people_code_label => 'Room check code';

  @override
  String get people_code_warning =>
      'This code is only a check value and cannot authorize joining by itself.';

  @override
  String get people_grant_title => 'Let them invite people';

  @override
  String get people_grant_hint =>
      'With this on, they can bring others into the room too.';

  @override
  String get people_granted_note =>
      'This invite also grants the right to invite others.';

  @override
  String get people_cannot_invite =>
      'You cannot invite people to this room. Ask the host to turn on “Let them invite people” when they invite you.';

  @override
  String get people_issue_error => 'Could not create the invite. Try again.';

  @override
  String get people_no_room => 'No room is selected.';

  @override
  String get people_wifi_title => 'Host Wi-Fi connection';

  @override
  String get people_ssid_label => 'Network';

  @override
  String get people_password_label => 'Password';

  @override
  String get people_wifi_ephemeral =>
      'These credentials belong only to the current connection, not the room.';

  @override
  String get people_wifi_recovering =>
      'Hotspot is recovering. The Wi-Fi QR refreshes when the new network is ready.';

  @override
  String people_in_room(Object count) {
    return 'IN THE ROOM ($count)';
  }

  @override
  String people_held_seats(Object count) {
    return 'OPEN SEATS ($count)';
  }

  @override
  String get roomjoin_title => 'JOIN A ROOM';

  @override
  String get roomjoin_hint =>
      'Point the camera at the invite on the host\'s phone. You go straight in.';

  @override
  String get roomjoin_searching => 'LOOKING FOR AN INVITE';

  @override
  String get roomjoin_locked => 'INVITE FOUND';

  @override
  String get roomjoin_joining => 'JOINING THE ROOM';

  @override
  String get roomjoin_not_joined =>
      'Could not join. Ask the host for a fresh invite.';

  @override
  String get roomjoin_bluetooth_permission =>
      'Joining needs the Nearby devices permission. Allow it, then scan again.';

  @override
  String get roomjoin_bluetooth_off => 'Turn on Bluetooth, then scan again.';

  @override
  String get roomjoin_location_off =>
      'On this phone, finding a nearby phone needs Location turned on. Turn it on in quick settings, then scan again.';

  @override
  String get roomjoin_host_not_found =>
      'Couldn\'t find their phone. Keep the invite open on it, stay close, and scan again.';

  @override
  String get roomjoin_invalid => 'That invite is invalid or expired.';

  @override
  String get roomjoin_not_our_code =>
      'That code isn\'t a Tarkk one. Scan the invite, or the Wi-Fi code, from the host\'s phone.';

  @override
  String reconnect_show_title(String name) {
    return 'Connect with $name';
  }

  @override
  String reconnect_show_step_start(String name) {
    return 'On $name\'s phone, open this room and tap Start.';
  }

  @override
  String get reconnect_show_step_hold =>
      'Their camera opens by itself. Hold this code in front of it.';

  @override
  String reconnect_waiting(String name) {
    return 'Waiting for $name…';
  }

  @override
  String get reconnect_preparing => 'Getting your phone ready…';

  @override
  String get reconnect_connecting => 'Connected — opening the call…';

  @override
  String get reconnect_switch_to_scan => 'Scan their code instead';

  @override
  String get reconnect_switch_to_show => 'Show my code instead';

  @override
  String get reconnect_scan_title => 'SCAN THEIR CODE';

  @override
  String reconnect_scan_hint(String name) {
    return 'Point the camera at the code on $name\'s phone.';
  }

  @override
  String get reconnect_scan_searching => 'LOOKING FOR THE CODE';

  @override
  String get reconnect_scan_locked => 'CODE FOUND';

  @override
  String get reconnect_scan_busy => 'CONNECTING';

  @override
  String reconnect_cannot_host(String name) {
    return 'This phone can\'t share a connection. On $name\'s phone, tap “Show my code instead”, then scan it here.';
  }

  @override
  String reconnect_not_our_code(String name) {
    return 'That isn\'t a Tarkk connection code. Scan the code on $name\'s phone.';
  }

  @override
  String get reconnect_wifi_off =>
      'Turn on Wi-Fi on this phone, then scan again.';

  @override
  String get reconnect_location_off =>
      'Turn on Location on this phone, then scan again.';

  @override
  String get reconnect_join_failed =>
      'Couldn\'t connect. Keep the phones close and scan again.';

  @override
  String get reconnect_host_failed =>
      'This phone couldn\'t start sharing. Try again, or tap “Scan their code instead”.';

  @override
  String get reconnect_retry => 'Try again';

  @override
  String get lobby_use_home_wifi => 'On the same Wi-Fi? Connect through it';

  @override
  String get roomjoin_other_version =>
      'This invite is from a different version of Tarkk. Update the app on both phones, then scan a fresh invite.';

  @override
  String get roomjoin_camera_denied =>
      'Tarkk needs the camera to read the host\'s invite.';

  @override
  String get roomjoin_camera_failed =>
      'The camera wouldn\'t start. Close whatever else is using it and try again.';

  @override
  String get roomjoin_open_settings => 'OPEN SETTINGS';

  @override
  String get archive_eyebrow => 'ARCHIVE';

  @override
  String get archive_title => 'Archived rooms';

  @override
  String get archive_blurb =>
      'These stay on this phone with their membership intact. Bring one back whenever you want it.';

  @override
  String get archive_restore => 'Restore';

  @override
  String get archive_delete => 'Delete';

  @override
  String get archive_delete_title => 'Delete room';

  @override
  String get archive_delete_action => 'Delete';

  @override
  String archive_member_count(Object count) {
    return '$count members';
  }

  @override
  String archive_delete_confirm(Object name) {
    return 'Deletes “$name” from this phone for good. If you only want it out of the list, archive it instead.';
  }

  @override
  String archive_card_semantics(String name, String count) {
    return '$name, archived, $count members';
  }

  @override
  String get inroom_alone_body =>
      'Show someone the room code and one scan puts them in here.';

  @override
  String get inroom_invite_someone => 'INVITE SOMEONE';

  @override
  String get inroom_add_someone => 'ADD SOMEONE';

  @override
  String get inroom_stranded_body =>
      'The others are in this room but nothing is reaching them — which means these phones are not on the same network.';

  @override
  String get inroom_get_on_one_network => 'GET ON ONE NETWORK';

  @override
  String get invite_people => 'People';

  @override
  String invite_people_count(Object count) {
    return 'Room people, $count in the room';
  }

  @override
  String get carrier_raising_host =>
      'Getting you set up to stay connected once you set off. This phone becomes the hub.';

  @override
  String get carrier_raising =>
      'Getting you set up to stay connected once you set off.';

  @override
  String get carrier_awaiting_host =>
      'One moment — getting the room ready for the road.';

  @override
  String get carrier_settled_host =>
      'This phone is the hub for the room. It stays off the internet until the room closes.';

  @override
  String get entry_create_room => 'CREATE ROOM';

  @override
  String get entry_create_room_hint => 'Start one and invite the others';

  @override
  String get entry_join_qr => 'JOIN WITH QR';

  @override
  String get entry_join_qr_hint => 'Scan the code on the host\'s phone';

  @override
  String get entry_resume_hint => 'Pick up where you left off';

  @override
  String get entry_join => 'JOIN';

  @override
  String get entry_join_hint => 'Scan a host\'s code';

  @override
  String get entry_new_room => 'NEW ROOM';

  @override
  String get entry_new_room_hint => 'Start your own';

  @override
  String get entry_my_rooms => 'MY ROOMS';

  @override
  String get issuer_title => 'Verify rider request';

  @override
  String get issuer_scan_hint =>
      'Scan the membership-request QR on the rider phone. Only a valid, unredeemed invite can be accepted.';

  @override
  String get issuer_verify_failed =>
      'Could not verify the request. Scan again.';

  @override
  String get issuer_accepted =>
      'Request verified. The rider must scan this response QR before membership is saved on their phone.';

  @override
  String get issuer_rejected =>
      'Request was not verified. This response only carries the rejection result.';

  @override
  String get issuer_done => 'Done';

  @override
  String header_room_semantics(String name, String code) {
    return 'Room $name, code $code';
  }

  @override
  String get header_alone_in_room => 'Alone in the room';

  @override
  String get header_alone => 'ALONE';

  @override
  String get entry_room_unavailable =>
      'This room is no longer available to start.';

  @override
  String get entry_back => 'Back';

  @override
  String get confirm_cancel => 'Cancel';

  @override
  String get consent_title_first => 'Before we start';

  @override
  String get consent_title_updated => 'We\'ve updated these';

  @override
  String get consent_body_first =>
      'Tarkk has no account and no server carrying your voice. These two documents say what that means in practice — and what it doesn\'t protect you from. The short version of each is below; the full text is one tap away.';

  @override
  String get consent_body_updated =>
      'The documents below have changed since you last agreed to them. Here\'s the short version of each, and the full text if you want it.';

  @override
  String get consent_accept => 'I agree — continue';

  @override
  String get consent_read_full => 'Read the full text';

  @override
  String get consent_effective_since => 'In effect since';

  @override
  String get consent_short_version => 'THE SHORT VERSION';

  @override
  String get consent_updated_badge => 'UPDATED';

  @override
  String get consent_new_badge => 'NEW';

  @override
  String get consent_partial_notice =>
      'This version of the app can\'t show part of this document. Read it in full at tarkk.ir.';

  @override
  String get bt_resume_title => 'Reconnecting over Bluetooth';

  @override
  String bt_resume_looking_for(String name) {
    return 'Looking for $name…';
  }

  @override
  String get bt_resume_waiting => 'Waiting for the other phone…';

  @override
  String get bt_resume_hint => 'Open Tarkk on the other phone too.';

  @override
  String bt_resume_connected_to(String name) {
    return 'Connected to $name';
  }

  @override
  String get bt_resume_connected => 'The other phone is connected';

  @override
  String get bt_resume_ask => 'Go to the channel now?';

  @override
  String get bt_resume_not_now => 'NOT NOW';

  @override
  String get bt_resume_failed =>
      'Couldn\'t reach the other phone. Try again when you\'re both nearby with Tarkk open.';

  @override
  String rooms_section(String count) {
    return 'Your rooms ($count)';
  }

  @override
  String get reconnect_wifi_needed_title => 'Turn on Wi-Fi';

  @override
  String reconnect_wifi_needed_body(String name) {
    return 'To connect with $name, this phone joins the connection $name\'s phone shares. That needs Wi-Fi on — no internet is used.';
  }

  @override
  String get reconnect_wifi_needed_action => 'Turn on Wi-Fi';

  @override
  String get reconnect_wifi_needed_waiting =>
      'The camera opens by itself as soon as Wi-Fi is on.';

  @override
  String get update_eyebrow => 'NEW VERSION';

  @override
  String update_title(String version) {
    return 'Tark $version is on the air';
  }

  @override
  String get update_body =>
      'A newer version is waiting on Bazaar. It takes about a minute.';

  @override
  String get update_required_eyebrow => 'UPDATE REQUIRED';

  @override
  String get update_required_title => 'This version is off the air';

  @override
  String update_required_body(String version) {
    return 'Update to Tark $version to keep talking. Everything you set up stays as it is.';
  }

  @override
  String get update_whats_new => 'WHAT\'S NEW';

  @override
  String get update_action => 'Update on Bazaar';

  @override
  String get update_later => 'Not now';

  @override
  String get update_open_failed => 'Bazaar didn\'t open. Try once more.';

  @override
  String get account_section_title => 'ACCOUNT';

  @override
  String get account_signed_out_body =>
      'An account is only needed for a subscription. Everything else in Tark works without one.';

  @override
  String get account_sign_in_row => 'Sign in or create an account';

  @override
  String get account_email_label => 'Email';

  @override
  String get account_change_password => 'Change password';

  @override
  String get account_sign_out => 'Sign out';

  @override
  String get account_sign_out_everywhere => 'Sign out on all phones';

  @override
  String get account_sign_out_everywhere_body =>
      'Every phone signed in to this account, this one included, will need to sign in again.';

  @override
  String get account_signed_out_toast => 'You\'re signed out.';

  @override
  String get account_delete => 'Delete account';

  @override
  String get signin_title => 'Sign in';

  @override
  String get signin_subtitle =>
      'A subscription belongs to your account, so it comes with you to any phone.';

  @override
  String get auth_email_hint => 'Email address';

  @override
  String get auth_password_hint => 'Password';

  @override
  String get auth_new_password_hint => 'New password (8 characters or more)';

  @override
  String get auth_current_password_hint => 'Current password';

  @override
  String get auth_name_hint => 'Your name';

  @override
  String get auth_show_password => 'Show password';

  @override
  String get auth_hide_password => 'Hide password';

  @override
  String get auth_close => 'CLOSE';

  @override
  String get signin_action => 'SIGN IN';

  @override
  String get signin_google => 'CONTINUE WITH GOOGLE';

  @override
  String get signin_or => 'or';

  @override
  String get signin_forgot => 'Forgot your password?';

  @override
  String get signin_create => 'New here? Create an account';

  @override
  String get signin_done => 'You\'re signed in.';

  @override
  String get register_title => 'Create an account';

  @override
  String get register_body =>
      'We\'ll email you a 6-digit code to confirm the address.';

  @override
  String get register_action => 'CREATE ACCOUNT';

  @override
  String get code_title => 'Check your email';

  @override
  String code_body(String email) {
    return 'We sent a 6-digit code to $email. Type it here, or open the link in that email on this phone.';
  }

  @override
  String get code_resend => 'SEND A NEW CODE';

  @override
  String code_resend_in(String time) {
    return 'You can ask for a new code in $time';
  }

  @override
  String get code_resent => 'A new code is on its way.';

  @override
  String get code_spam_hint =>
      'Nothing yet? Have a look in your spam folder too.';

  @override
  String get code_verifying => 'Checking…';

  @override
  String get code_start_over => 'START AGAIN';

  @override
  String get code_link_elsewhere_title => 'Type the code instead';

  @override
  String get code_link_elsewhere_body =>
      'This link is for a sign-up or password reset that was started on another phone, or has already finished. On the phone where you started, type the 6-digit code from the same email.';

  @override
  String get forgot_title => 'Reset your password';

  @override
  String get forgot_body =>
      'Type your account\'s email. If there\'s an account with it, we\'ll send a code there.';

  @override
  String get forgot_action => 'SEND CODE';

  @override
  String get reset_title => 'Choose a new password';

  @override
  String get reset_body =>
      'You\'ll be signed in here, and signed out on your other phones.';

  @override
  String get reset_action => 'SAVE AND SIGN IN';

  @override
  String get change_password_body =>
      'Your other phones will be signed out; this one stays signed in.';

  @override
  String get change_password_action => 'SAVE';

  @override
  String get change_password_done => 'Password changed.';

  @override
  String get google_link_title => 'You already have an account';

  @override
  String google_link_body(String email) {
    return '$email already has a Tark account with a password. Type that password once to add Google sign-in to it.';
  }

  @override
  String get google_link_action => 'ADD GOOGLE AND SIGN IN';

  @override
  String get google_name_title => 'What should we call you?';

  @override
  String get google_name_action => 'CONTINUE';

  @override
  String get delete_title => 'Delete account';

  @override
  String get delete_warning =>
      'This deletes your account and everything kept with it, right away and for good. It can\'t be undone.';

  @override
  String get delete_keeps =>
      'Tark itself keeps working on this phone: your rooms, name and settings stay here.';

  @override
  String delete_type_email(String email) {
    return 'To confirm, type your account\'s email: $email';
  }

  @override
  String get delete_google_note =>
      'You\'ll confirm it\'s you with your Google account.';

  @override
  String get delete_sub_title => 'Your Bazaar subscription is still running';

  @override
  String get delete_sub_body_renewing =>
      'Deleting the account doesn\'t cancel it: Bazaar keeps renewing it until you cancel it in Bazaar. You can restore the purchase into a new account later.';

  @override
  String get delete_sub_body =>
      'Deleting the account doesn\'t refund it. You can restore the purchase into a new account later.';

  @override
  String get delete_sub_ack => 'I understand';

  @override
  String get delete_action => 'DELETE MY ACCOUNT';

  @override
  String get delete_action_google => 'CONFIRM WITH GOOGLE AND DELETE';

  @override
  String get delete_confirm_title => 'Delete your account for good?';

  @override
  String get delete_confirm_body =>
      'There\'s no undo. Your subscription purchase can be restored into a new account later.';

  @override
  String get delete_done => 'Your account was deleted.';

  @override
  String get auth_error_offline =>
      'Couldn\'t reach Tark. Check that this phone is online, then try again.';

  @override
  String get auth_error_trouble =>
      'Something went wrong on our side. Please try again in a moment.';

  @override
  String get auth_error_rate_limited =>
      'That\'s a lot of tries in a short time. Please wait a little, then try again.';

  @override
  String get auth_error_fill => 'Please fill in every field.';

  @override
  String get auth_error_email => 'That email address doesn\'t look complete.';

  @override
  String get auth_error_name =>
      'That name has characters we can\'t show. Try another one.';

  @override
  String get auth_error_check_input =>
      'Please check what you typed and try again.';

  @override
  String get auth_error_credentials =>
      'That email and password don\'t match an account.';

  @override
  String get auth_error_password_wrong => 'That password doesn\'t match.';

  @override
  String auth_error_account_disabled(String email) {
    return 'This account is on hold. Write to us at $email and we\'ll sort it out.';
  }

  @override
  String get auth_error_password_short => 'Use 8 characters or more.';

  @override
  String get auth_error_password_long => 'Use 128 characters or fewer.';

  @override
  String get auth_error_password_common =>
      'That password is easy to guess. Try a longer or less common one.';

  @override
  String get auth_error_password_email =>
      'The password can\'t be your email address.';

  @override
  String get auth_error_password_invalid =>
      'That password can\'t be used. Try another one.';

  @override
  String get auth_error_password_unchanged =>
      'That\'s the current password. Pick a new one.';

  @override
  String get auth_error_password_not_set =>
      'This account signs in with Google and has no password yet. Use “Forgot your password?” to add one.';

  @override
  String auth_error_code(String count) {
    return 'That code doesn\'t match. $count tries left.';
  }

  @override
  String get auth_error_code_plain => 'That code doesn\'t match.';

  @override
  String get auth_error_code_locked =>
      'That\'s a lot of codes tried. Send a new code to carry on.';

  @override
  String get auth_error_flow_expired =>
      'This code has run out of time. Start again to get a new one.';

  @override
  String get auth_error_flow_gone =>
      'This code can\'t be used any more. Please start again.';

  @override
  String get auth_error_resend_limit =>
      'That\'s as many codes as we can send for this one. Please start again.';

  @override
  String get auth_error_already_registered =>
      'This address already has an account. Sign in instead.';

  @override
  String get auth_error_google_unavailable =>
      'Google sign-in isn\'t available right now. You can use email and password instead.';

  @override
  String get auth_error_google_retry =>
      'Google sign-in didn\'t finish. Please try again.';

  @override
  String get auth_error_google_unverified =>
      'Google hasn\'t confirmed this Google account\'s email yet. Confirm it with Google, or use email and password.';

  @override
  String get auth_error_google_unsupported =>
      'This Google account\'s email can\'t be used with Tark. Try another account, or email and password.';

  @override
  String get auth_error_account_conflict =>
      'This address is linked to a different Google account. Sign in with that one, or with your password.';

  @override
  String get auth_error_ticket_expired =>
      'That took a while, so it timed out. Please start again.';

  @override
  String get auth_error_confirmation =>
      'That isn\'t the account\'s email. Type it exactly as shown.';

  @override
  String get auth_error_signed_out =>
      'You\'ve been signed out. Please sign in again.';

  @override
  String auth_error_reauth(String email) {
    return 'We can\'t confirm it\'s you on this phone. Write to us at $email and we\'ll help.';
  }

  @override
  String get sub_signin_action => 'SIGN IN';

  @override
  String get room_member_away => 'Dropped out';

  @override
  String room_member_waiting_back(String name) {
    return 'Waiting for $name to come back';
  }

  @override
  String get room_rejoin_show_code => 'Show your code';

  @override
  String room_rejoin_scan_code(String name) {
    return 'Scan $name\'s code';
  }

  @override
  String room_rejoin_code_title(String name) {
    return 'Show this to $name';
  }

  @override
  String room_rejoin_code_step_open(String name) {
    return 'On $name\'s phone, open Tarkk and tap “Go back”.';
  }

  @override
  String get room_rejoin_code_step_scan =>
      'If it asks for a code, scan this one.';

  @override
  String room_rejoin_code_back(String name) {
    return '$name is back';
  }

  @override
  String rejoin_prompt_title_person(String name) {
    return 'Get back to $name?';
  }

  @override
  String rejoin_prompt_title_room(String room) {
    return 'Get back to “$room”?';
  }

  @override
  String rejoin_prompt_body(String room) {
    return 'You dropped out of “$room”. You can go right back in.';
  }

  @override
  String get rejoin_prompt_go => 'Go back';

  @override
  String get rejoin_prompt_not_now => 'Not now';

  @override
  String get rejoin_quiet_failed =>
      'Couldn\'t get back on its own. One quick scan and you\'re in.';

  @override
  String get alone_leaving_in => 'Leaving the room in';

  @override
  String get alone_seconds => 'seconds';

  @override
  String alone_body(String minutes) {
    return 'Nobody else has been here for $minutes minutes.';
  }

  @override
  String get alone_stay => 'Stay longer';

  @override
  String get alone_leave_now => 'Leave now';
}
