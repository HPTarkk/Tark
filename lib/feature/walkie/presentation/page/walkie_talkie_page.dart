import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';
import '../widget/music_cast_section.dart';
import '../widget/status_row.dart';
import '../widget/user_list.dart';
import '../widget/visualizer_section.dart';
import '../widget/vox_section.dart';
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
  // Staggered entrance: [header, identityCard, visualizer, statusRow, members, vox, footer]
  late AnimationController _entranceController;
  late List<Animation<double>> _entranceSections;

  @override
  void initState() {
    super.initState();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    const starts = [0.0, 0.10, 0.22, 0.36, 0.48, 0.62, 0.75];
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
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  // Pass child through so the builder doesn't recreate it on every tick.
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
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
                      _buildLinkBanner(),
                      _entrance(3, const StatusRow()),
                      const SizedBox(height: 20),
                      // VOX above the member list: it's the control the
                      // rider actually adjusts, while members are a static
                      // two-entry list in practice.
                      _entrance(4, const VoxSection()),
                      // Renders nothing where playback capture is
                      // unsupported (iOS, Android < 10) — spacing lives
                      // inside the section so nothing doubles up here.
                      _entrance(5, const MusicCastSection()),
                      const SizedBox(height: 20),
                      _entrance(6, const UserList()),
                    ],
                  ),
                ),
              ),
              _buildLeaveButton(context),
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: VersionBadge(
                    color: AppColors.textSecondary.withAlpha(60),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Identity Card ───────────────────────────────────────────────────────────
  Widget _buildIdentityCard(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.localId != c.localId || p.myName != c.myName || p.isReady != c.isReady,
      builder: (context, state) {
        final s = context.getString;
        final displayIp = state.localId.isEmpty
            ? s.connecting
            : (state.transferMode == TransferMode.bluetooth
                ? s.transport_bluetooth
                : state.localId.localized(context));

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
                          onTap: () =>
                              _showEditNameDialog(context, state.myName),
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
                        Icon(
                          Icons.router_rounded,
                          color: AppColors.textSecondary,
                          size: 12,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: TickerText(
                            text: displayIp,
                            duration: const Duration(milliseconds: 300),
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
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

  // ── Bluetooth link-down banner ──────────────────────────────────────────────
  Widget _buildLinkBanner() {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.isLinkDown != c.isLinkDown,
      builder: (context, state) => AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: !state.isLinkDown
            ? const SizedBox(width: double.infinity)
            : Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.amber.withAlpha(130)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: AppColors.amber,
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.getString.bt_link_reconnecting,
                        style: TextStyle(
                          color: AppColors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  // ── Leave Button ─────────────────────────────────────────────────────────────
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

  // ── Dialogs ─────────────────────────────────────────────────────────────────
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
              // goNamed (not pop) so leaving always lands cleanly on
              // Landing regardless of how this screen was reached — the
              // Bluetooth flow replaces the stack on connect (goNamed in
              // BluetoothConnectPage), which left plain pop() with nothing
              // to pop back to.
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

  void _showEditNameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
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
          s.set_name_title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle:
                TextStyle(color: AppColors.textSecondary.withAlpha(160)),
            counterStyle:
                TextStyle(color: AppColors.textSecondary.withAlpha(120)),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.amber),
            ),
          ),
          onSubmitted: (v) {
            context.read<WalkieTalkieCubit>().setMyName(v);
            Navigator.of(ctx).pop();
          },
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
              context.read<WalkieTalkieCubit>().setMyName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: Text(
              s.save,
              style: TextStyle(
                color: AppColors.amber,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared card ────────────────────────────────────────────────────────────────

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
