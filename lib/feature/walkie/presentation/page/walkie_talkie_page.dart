import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/identity/device_identity.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../room/presentation/widget/carrier_handover_note.dart';
import '../../../room/presentation/widget/room_visuals.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';
import '../widget/background_permission_banner.dart';
import '../widget/channel_recovery.dart';
import '../widget/connection_health_banner.dart';
import '../widget/mic_control.dart';
import '../widget/music_cast_section.dart';
import '../widget/peer_departure_banner.dart';
import '../widget/role_badge.dart';
import '../widget/usage_tips_sheet.dart';
import '../widget/user_list.dart';
import '../widget/visualizer_section.dart';
import '../widget/walkie_header.dart';

class WalkieTalkiePage extends StatefulWidget {
  const WalkieTalkiePage._();

  static Widget buildPage() {
    return BlocProvider<WalkieTalkieCubit>(
      create: (_) => GetIt.instance<WalkieTalkieCubit>(),
      child: const WalkieTalkiePage._(),
    );
  }

  @override
  State<WalkieTalkiePage> createState() => _WalkieTalkiePageState();
}

class _WalkieTalkiePageState extends State<WalkieTalkiePage> {
  StreamSubscription<String>? _systemAudioMsgSub;
  Timer? _usageTipsTimer;

  @override
  void initState() {
    super.initState();

    // One-shot toast for system-audio sharing notices (currently just the
    // capture-stalled case — see WalkieTalkieCubit.toggleShareSystemAudio).
    _systemAudioMsgSub = context
        .read<WalkieTalkieCubit>()
        .systemAudioMessages
        .listen((code) {
          if (!mounted) return;
          final text = switch (code) {
            'capture_stalled' => context.getString.music_cast_stalled,
            // Same cause, different outcome: capture is still running and the
            // cast is still up, so the wording must not claim it stopped.
            'capture_blocked' => context.getString.music_cast_blocked,
            _ => null,
          };
          if (text == null) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(text)));
        });

    _scheduleUsageTips();
  }

  // Shown once ever, at a randomized moment a few seconds into a session
  // (not necessarily first launch) rather than the instant the page opens.
  Future<void> _scheduleUsageTips() async {
    final repository = GetIt.instance<SettingsRepository>();
    final alreadyShown = await repository.getUsageTipsShown();
    if (alreadyShown || !mounted) return;
    final delay = Duration(seconds: 4 + Random().nextInt(7));
    _usageTipsTimer = Timer(delay, () async {
      if (!mounted) return;
      await repository.setUsageTipsShown(true);
      if (!mounted) return;
      showUsageTipsSheet(context);
    });
  }

  @override
  void dispose() {
    _systemAudioMsgSub?.cancel();
    _usageTipsTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // System back gets the same confirmation as the on-screen Leave, rather
      // than dropping the channel outright. Two reasons: this page is often
      // the ONLY route (quick access and the home-screen widget both land
      // straight here in Wi-Fi mode), so an unhandled back closes the app
      // mid-session; and leaving is destructive enough — it tears down the
      // transport and the keep-alive service — to be worth confirming when
      // the phone is in a pocket. The dialog is its own route, so a second
      // back dismisses it instead of re-triggering this.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave(context);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppColors.systemOverlayStyle.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: _buildScaffold(context),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const WalkieHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                // The Room lobby's entrance: one shared controller, each
                // section rising a little after the one above it.
                child: StaggeredEntrance(
                  builder: (context, children) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                  children: [
                    _buildIdentityCard(context),
                    const SizedBox(height: 16),
                    const VisualizerSection(),
                    const SizedBox(height: 16),
                    const BackgroundPermissionBanner(),
                    // Above the link banner and the mic control: when this
                    // fires it is about to change what the channel is running
                    // over, which is context for everything below it.
                    const CarrierHandoverNote(),
                    _buildLinkBanner(),
                    // Above the mic card on purpose: every issue it can show
                    // is a reason the control below is lying about being
                    // live, so it has to be read first.
                    const ChannelIssueBanner(),
                    // Self-mute: the one control a hands-free rider needs
                    // in-channel — go silent without leaving. Sits where
                    // the old TX/RX chips were; that status now lives in
                    // the visualizer's pill above.
                    const MicControl(),
                    // Renders nothing where playback capture is
                    // unsupported (iOS, Android < 10) — spacing lives
                    // inside the section so nothing doubles up here.
                    const MusicCastSection(),
                    const SizedBox(height: 20),
                    _buildPeerDepartureBanner(),
                    const UserList(),
                  ],
                ),
              ),
            ),
            _buildLeaveButton(context),
            // Pinned below the scroll view rather than inside it: the whole
            // promise of the help sheet is that it's reachable the moment
            // something feels wrong, and a user who has to go looking for it
            // has already been stuck for longer than they should have been.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const ChannelHelpButton(),
                  VersionBadge(color: AppColors.textSecondary.withAlpha(60)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Identity Card ───────────────────────────────────────────────────────────
  Widget _buildIdentityCard(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.localId != c.localId ||
          p.myName != c.myName ||
          p.isReady != c.isReady ||
          p.myRole != c.myRole ||
          p.connectionHealth.isLive != c.connectionHealth.isLive,
      builder: (context, state) {
        final s = context.getString;
        // How you're connected, said with the transport's own glyph. This
        // line used to spell out "Bluetooth" — or, in every other mode, print
        // the device's IP address, which is not something a person can use.
        final isConnecting = state.localId.isEmpty;
        // final transportIcon = switch (state.transferMode) {
        //   TransferMode.bluetooth => Icons.bluetooth_rounded,
        //   TransferMode.hotspot => Icons.wifi_tethering_rounded,
        //   TransferMode.guest => Icons.public_rounded,
        //   TransferMode.wifi => Icons.wifi_rounded,
        // };

        // Lit like the lobby's hero while the link is up, so the card you
        // pressed Start on is visibly the same one, now live. Unlit while
        // connecting or reconnecting — the banners below say why.
        final live = !isConnecting && state.connectionHealth.isLive;
        return AnimatedContainer(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.all(16),
          decoration: roomCardDecoration(
            lit: live,
            radius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              // The same tinted face the other phones draw for this one.
              TintedAvatar(
                seed: GetIt.instance.isRegistered<DeviceIdentity>()
                    ? GetIt.instance<DeviceIdentity>().id
                    : state.myName,
                name: state.myName,
                size: 52,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            state.myName.isEmpty ? '...' : state.myName,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => context.pushNamed(
                            AppRoutes.settingsName,
                            extra: context.read<WalkieTalkieCubit>(),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.border,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.edit_rounded,
                                  color: AppColors.amber,
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  s.edit_name,
                                  style: TextStyle(
                                    color: AppColors.amber,
                                    fontSize: 10,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        // Icon(
                        //   transportIcon,
                        //   color: AppColors.textSecondary,
                        //   size: 13,
                        // ),
                        // While connecting, that's the whole story. Once the
                        // link is up the glyph carries how, and the badge
                        // carries which part you're playing in it — the same
                        // line every other member shows in the roster below.
                        if (isConnecting) ...[
                          // const SizedBox(width: 4),
                          Expanded(
                            child: TickerText(
                              text: s.connecting,
                              duration: const Duration(milliseconds: 300),
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                                letterSpacing: 0.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ] else if (state.myRole != SessionRole.unknown) ...[
                          // const SizedBox(width: 6),
                          Expanded(
                            child: RoleBadge(role: state.myRole, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Connection health banner ────────────────────────────────────────────────
  Widget _buildLinkBanner() {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.connectionHealth != c.connectionHealth,
      builder: (context, state) => ConnectionHealthBanner(
        health: state.connectionHealth,
        transferMode: state.transferMode,
        onRetry: () => context.read<WalkieTalkieCubit>().retryNow(),
      ),
    );
  }

  // ── Peer departure banner ───────────────────────────────────────────────────
  Widget _buildPeerDepartureBanner() {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.lastPeerDeparture != c.lastPeerDeparture,
      builder: (context, state) =>
          PeerDepartureBanner(departure: state.lastPeerDeparture),
    );
  }

  // ── Leave Button ─────────────────────────────────────────────────────────────
  Widget _buildLeaveButton(BuildContext context) {
    final s = context.getString;
    return Padding(
      // Top gap so scrolled content doesn't run flush into the button.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      // Announced as a button; a bare GestureDetector was read as plain text.
      child: Semantics(
        button: true,
        child: PressableScale(
          onTap: () => _confirmLeave(context),
          borderRadius: BorderRadius.circular(20),
          // Quieter than the controls above it: an outline, not a fill. It
          // is the one exit, but not the thing a rider should reach for.
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.red.withAlpha(90)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.power_settings_new_rounded,
                  color: AppColors.red.withAlpha(210),
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(
                  s.leave_channel,
                  style: TextStyle(
                    color: AppColors.red.withAlpha(210),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Dialogs ─────────────────────────────────────────────────────────────────
  // A bottom sheet, like the Room screens' own confirmations: the safe
  // choice is the wide, easy one, and leaving costs a deliberate reach. The
  // sheet is its own route, so a second back dismisses it instead of
  // re-triggering the PopScope above.
  Future<void> _confirmLeave(BuildContext context) async {
    final s = context.getString;
    final leave = await showConfirmSheet(
      context,
      title: s.leave_channel_confirm_title,
      body: s.leave_channel_confirm_message,
      action: s.leave,
      icon: Icons.power_settings_new_rounded,
      destructive: true,
    );
    if (!leave || !context.mounted) return;
    Sfx.play(SfxEvent.channelLeave);
    // goNamed (not pop) so leaving always lands cleanly on Landing regardless
    // of how this screen was reached — the Bluetooth flow replaces the stack
    // on connect (goNamed in BluetoothConnectPage), which left plain pop()
    // with nothing to pop back to.
    context.goNamed(AppRoutes.landingName);
  }
}
