import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/home_widget/widget_control_channel.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';
import '../widget/background_permission_banner.dart';
import '../widget/channel_recovery.dart';
import '../widget/connection_health_banner.dart';
import '../widget/mic_control.dart';
import '../widget/music_cast_section.dart';
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

class _WalkieTalkiePageState extends State<WalkieTalkiePage>
    with TickerProviderStateMixin {
  late AnimationController _entranceController;
  late List<Animation<double>> _entranceSections;
  StreamSubscription<String>? _systemAudioMsgSub;
  StreamSubscription<WidgetControlAction>? _watchControlSub;
  Timer? _usageTipsTimer;

  @override
  void initState() {
    super.initState();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    const starts = [0.0, 0.10, 0.22, 0.38, 0.52, 0.66];
    _entranceSections = starts
        .map(
          (s) => CurvedAnimation(
            parent: _entranceController,
            curve: Interval(
              s,
              (s + 0.38).clamp(0.0, 1.0),
              curve: Curves.easeOutCubic,
            ),
          ),
        )
        .toList();

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _entranceController.forward(),
    );

    _systemAudioMsgSub = context
        .read<WalkieTalkieCubit>()
        .systemAudioMessages
        .listen((code) {
          if (!mounted) return;
          final text = switch (code) {
            'capture_stalled' => context.getString.music_cast_stalled,
            _ => null,
          };
          if (text == null) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(text)));
        });

    // The watch's music button controls the exact same system-audio sharing
    // state as the phone UI. Keeping this listener on the live room page means
    // a stale watch command cannot start a second session outside a channel.
    _watchControlSub = GetIt.instance<WidgetControlChannel>().actions.listen((
      action,
    ) {
      if (!mounted || action != WidgetControlAction.toggleMusic) return;
      unawaited(
        context.read<WalkieTalkieCubit>().toggleShareSystemAudio(),
      );
    });

    _scheduleUsageTips();
  }

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
    _entranceController.dispose();
    _systemAudioMsgSub?.cancel();
    _watchControlSub?.cancel();
    _usageTipsTimer?.cancel();
    super.dispose();
  }

  Widget _entrance(int index, Widget child) => AnimatedBuilder(
    animation: _entranceSections[index],
    child: child,
    builder: (_, prebuilt) => Opacity(
      opacity: _entranceSections[index].value,
      child: Transform.translate(
        offset: Offset(0, 22 * (1 - _entranceSections[index].value)),
        child: prebuilt,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
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
            _entrance(0, const WalkieHeader()),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _entrance(1, _buildIdentityCard(context)),
                    const SizedBox(height: 16),
                    _entrance(2, const VisualizerSection()),
                    const SizedBox(height: 16),
                    const BackgroundPermissionBanner(),
                    _buildLinkBanner(),
                    const ChannelIssueBanner(),
                    _entrance(3, const MicControl()),
                    _entrance(4, const MusicCastSection()),
                    const SizedBox(height: 20),
                    _entrance(5, const UserList()),
                  ],
                ),
              ),
            ),
            _buildLeaveButton(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const ChannelHelpButton(),
                  VersionBadge(
                    color: AppColors.textSecondary.withAlpha(60),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdentityCard(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.localId != c.localId ||
          p.myName != c.myName ||
          p.isReady != c.isReady ||
          p.myRole != c.myRole,
      builder: (context, state) {
        final s = context.getString;
        final isConnecting = state.localId.isEmpty;

        return _GlowCard(
          child: Row(
            children: [
              AppAvatar(name: state.myName, isActive: true, size: 52),
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
                        if (isConnecting)
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
                          )
                        else if (state.myRole != SessionRole.unknown)
                          Expanded(
                            child: RoleBadge(role: state.myRole, fontSize: 12),
                          ),
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

  Widget _buildLeaveButton(BuildContext context) {
    final s = context.getString;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        onTap: () => _confirmLeave(context),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(
            color: AppColors.red.withAlpha(18),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.red.withAlpha(90),
              width: 1.5,
            ),
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
    );
  }

  void _confirmLeave(BuildContext context) {
    final s = context.getString;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.border),
        ),
        title: Text(
          s.leave_channel_confirm_title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          s.leave_channel_confirm_message,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              s.cancel,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Sfx.play(SfxEvent.channelLeave);
              context.goNamed(AppRoutes.landingName);
            },
            child: Text(
              s.leave,
              style: TextStyle(
                color: AppColors.red,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowCard extends StatelessWidget {
  final Widget child;

  const _GlowCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: child,
    );
  }
}
