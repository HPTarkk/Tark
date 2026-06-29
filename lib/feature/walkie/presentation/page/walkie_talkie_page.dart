import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../../feature/audio/presentation/widget/audio_visualizer.dart';
import '../../../../feature/audio/domian/entity/recorded_audio_data.dart';
import '../../../../feature/walkie/domain/entity/channel_user.dart';
import '../manager/walkie_talkie_cubit.dart';

// ── Colors ──────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF080B14);
const _kSurface = Color(0xFF0F1320);
const _kCard = Color(0xFF141929);
const _kBorder = Color(0xFF1E2845);
const _kAmber = Color(0xFFFFB74D);
const _kAmberDim = Color(0xFFFF8F00);
const _kRed = Color(0xFFEF5350);
const _kGreen = Color(0xFF4CAF50);
const _kTextPrimary = Color(0xFFECEFF1);
const _kTextSecondary = Color(0xFF78909C);

class WalkieTalkiePage extends StatefulWidget {
  static const path = 'walkie';
  static const name = 'WalkieTalkiePage';

  const WalkieTalkiePage._();

  static Widget buildPage() => BlocProvider<WalkieTalkieCubit>(
        create: (_) => GetIt.instance<WalkieTalkieCubit>(),
        child: const WalkieTalkiePage._(),
      );

  @override
  State<WalkieTalkiePage> createState() => _WalkieTalkiePageState();
}

class _WalkieTalkiePageState extends State<WalkieTalkiePage>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _scanController;

  // Staggered entrance: [header, identityCard, visualizer, statusRow, members, vox, footer]
  late AnimationController _entranceController;
  late List<Animation<double>> _entranceSections;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );

    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    const starts = [0.0, 0.10, 0.22, 0.36, 0.48, 0.62, 0.75];
    _entranceSections = starts
        .map((s) => CurvedAnimation(
              parent: _entranceController,
              curve: Interval(s, (s + 0.38).clamp(0.0, 1.0),
                  curve: Curves.easeOutCubic),
            ))
        .toList();

    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _entranceController.forward());
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  Widget _entrance(int index, Widget child) => AnimatedBuilder(
        animation: _entranceSections[index],
        builder: (_, _) => Opacity(
          opacity: _entranceSections[index].value,
          child: Transform.translate(
            offset: Offset(0, 22 * (1 - _entranceSections[index].value)),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: _kBg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: _kBg,
        body: BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
          builder: (context, state) => SafeArea(
            child: Column(
              children: [
                _entrance(0, _buildHeader(context, state)),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _entrance(1, _buildIdentityCard(context, state)),
                        const SizedBox(height: 16),
                        _entrance(2, _buildVisualizerSection(context, state)),
                        const SizedBox(height: 16),
                        _entrance(3, _buildStatusRow(context, state)),
                        const SizedBox(height: 20),
                        _entrance(4, _buildUsersSection(context, state)),
                        const SizedBox(height: 20),
                        _entrance(5, _buildVoxSection(context, state)),
                        const SizedBox(height: 8),
                        _entrance(6, _buildFooter()),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),
                _buildLeaveButton(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader(BuildContext context, WalkieTalkieState state) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(bottom: BorderSide(color: _kBorder, width: 1)),
      ),
      child: Row(
        children: [
          _RadioIcon(),
          const SizedBox(width: 10),
          Text(
            s.app_name,
            style: const TextStyle(
              color: _kAmber,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
            ),
          ),
          const Spacer(),
          _buildSignalIndicator(context, state),
        ],
      ),
    );
  }

  Widget _buildSignalIndicator(BuildContext context, WalkieTalkieState state) {
    final isActive = state.isReady &&
        state.localIp.isNotEmpty &&
        state.localIp != '0.0.0.0';
    final s = context.getString;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (_, _) => Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Color.lerp(
                      _kGreen,
                      _kGreen.withAlpha(100),
                      _pulseAnimation.value,
                    )!
                  : _kTextSecondary,
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: _kGreen.withAlpha(150),
                        blurRadius: 8 * _pulseAnimation.value,
                      )
                    ]
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Text(
            isActive ? s.live : s.offline,
            key: ValueKey(isActive),
            style: TextStyle(
              color: isActive ? _kGreen : _kTextSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        ),
      ],
    );
  }

  // ── Identity Card ───────────────────────────────────────────────────────────
  Widget _buildIdentityCard(BuildContext context, WalkieTalkieState state) {
    final s = context.getString;
    final displayIp = state.localIp.isEmpty
        ? s.connecting
        : state.localIp.localized(context);

    return _GlowCard(
      child: Row(
        children: [
          _AvatarWidget(name: state.myName, isActive: true, size: 52),
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
                        style: const TextStyle(
                          color: _kTextPrimary,
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
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _kBorder,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.edit_rounded,
                                color: _kAmber, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              s.edit_name,
                              style: const TextStyle(
                                color: _kAmber,
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
                    const Icon(Icons.router_rounded,
                        color: _kTextSecondary, size: 12),
                    const SizedBox(width: 4),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          displayIp,
                          key: ValueKey(displayIp),
                          style: const TextStyle(
                            color: _kTextSecondary,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
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
  }

  // ── Visualizer ──────────────────────────────────────────────────────────────
  Widget _buildVisualizerSection(
      BuildContext context, WalkieTalkieState state) {
    final s = context.getString;
    final isActive = state.isTransmitting || state.isSomeoneElseTalking;
    final color = state.isTransmitting ? _kRed : _kAmber;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 120,
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? color.withAlpha(120) : _kBorder,
          width: 1.5,
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                    color: color.withAlpha(40), blurRadius: 20, spreadRadius: 2)
              ]
            : null,
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          _ScanlineBackground(),
          if (state.currentSamples.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: AudioVisualizer(
                audioData: RecordedAudioData(state.currentSamples),
                barCount: 48,
                color: color,
              ),
            )
          else
            Center(
              child: Text(
                state.isReady ? s.monitoring : s.initializing,
                style: TextStyle(
                  color: _kTextSecondary.withAlpha(120),
                  fontSize: 12,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Status Row ──────────────────────────────────────────────────────────────
  Widget _buildStatusRow(BuildContext context, WalkieTalkieState state) {
    return Row(
      children: [
        Expanded(child: _buildTxStatus(context, state)),
        const SizedBox(width: 12),
        Expanded(child: _buildRxStatus(context, state)),
      ],
    );
  }

  Widget _buildTxStatus(BuildContext context, WalkieTalkieState state) {
    final active = state.isTransmitting;
    final s = context.getString;
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? _kRed.withAlpha(30) : _kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? Color.lerp(
                    _kRed, _kRed.withAlpha(100), _pulseAnimation.value)!
                : _kBorder,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _kRed : _kBorder,
                boxShadow: active
                    ? [BoxShadow(color: _kRed.withAlpha(180), blurRadius: 8)]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              s.tx_label,
              style: TextStyle(
                color: active ? _kRed : _kTextSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRxStatus(BuildContext context, WalkieTalkieState state) {
    final active = state.isSomeoneElseTalking;
    final s = context.getString;
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? _kGreen.withAlpha(25) : _kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? Color.lerp(
                    _kGreen, _kGreen.withAlpha(100), _pulseAnimation.value)!
                : _kBorder,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _kGreen : _kBorder,
                boxShadow: active
                    ? [
                        BoxShadow(
                            color: _kGreen.withAlpha(180), blurRadius: 8)
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              s.rx_label,
              style: TextStyle(
                color: active ? _kGreen : _kTextSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Users Section ───────────────────────────────────────────────────────────
  Widget _buildUsersSection(BuildContext context, WalkieTalkieState state) {
    final s = context.getString;
    final users = state.activeUsers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          label: s.channel_members,
          badge: users.isEmpty ? null : users.length.localized(context),
        ),
        const SizedBox(height: 10),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: users.isEmpty
                ? Container(
                    key: const ValueKey('empty'),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _kCard,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _kBorder),
                    ),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.wifi_tethering_off_rounded,
                              color: _kTextSecondary.withAlpha(120), size: 32),
                          const SizedBox(height: 8),
                          Text(
                            s.no_users_on_network,
                            style: TextStyle(
                              color: _kTextSecondary.withAlpha(160),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : Column(
                    key: const ValueKey('list'),
                    children: users
                        .map((u) => Padding(
                              key: ValueKey(u.ip),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _UserTile(
                                  user: u, pulseAnimation: _pulseAnimation),
                            ))
                        .toList(),
                  ),
          ),
        ),
      ],
    );
  }

  // ── VOX Section ─────────────────────────────────────────────────────────────
  Widget _buildVoxSection(BuildContext context, WalkieTalkieState state) {
    final s = context.getString;
    final sensitivityPercent =
        ((state.voxThreshold - 0.005) / (0.15 - 0.005) * 100)
            .clamp(0.0, 100.0);
    final invertedPercent = (100 - sensitivityPercent).toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(label: s.vox_sensitivity),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kBorder),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    s.vox_threshold,
                    style: const TextStyle(
                      color: _kTextSecondary,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _kBorder,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        '${invertedPercent.localized(context)}%',
                        key: ValueKey(invertedPercent),
                        style: const TextStyle(
                          color: _kAmber,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: _kAmber,
                  inactiveTrackColor: _kBorder,
                  thumbColor: _kAmber,
                  overlayColor: _kAmber.withAlpha(40),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 9),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 18),
                ),
                child: Slider(
                  value: state.voxThreshold,
                  min: 0.005,
                  max: 0.15,
                  onChanged: (v) =>
                      context.read<WalkieTalkieCubit>().setVoxThreshold(v),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s.voice_quiet,
                      style: TextStyle(
                          color: _kTextSecondary.withAlpha(160),
                          fontSize: 10,
                          letterSpacing: 1)),
                  Text(s.voice_loud,
                      style: TextStyle(
                          color: _kTextSecondary.withAlpha(160),
                          fontSize: 10,
                          letterSpacing: 1)),
                ],
              ),
              const SizedBox(height: 10),
              _VoxMeter(
                  rms: state.currentRms, threshold: state.voxThreshold),
            ],
          ),
        ),
        if (!state.hasPermission)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kRed.withAlpha(25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kRed.withAlpha(100)),
            ),
            child: Row(
              children: [
                const Icon(Icons.mic_off_rounded, color: _kRed, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.getString.mic_permission_denied,
                    style: const TextStyle(color: _kRed, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────────────
  Widget _buildFooter() {
    return Center(child: VersionBadge(color: _kTextSecondary.withAlpha(60)));
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
            color: _kRed.withAlpha(18),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kRed.withAlpha(90), width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.power_settings_new_rounded,
                  color: _kRed.withAlpha(210), size: 18),
              const SizedBox(width: 10),
              Text(
                s.leave_channel,
                style: TextStyle(
                  color: _kRed.withAlpha(210),
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
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _kBorder),
        ),
        title: Text(
          s.leave_channel_confirm_title,
          style: const TextStyle(
              color: _kTextPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          s.leave_channel_confirm_message,
          style: const TextStyle(color: _kTextSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel,
                style: const TextStyle(color: _kTextSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.pop();
            },
            child: Text(s.leave,
                style:
                    const TextStyle(color: _kRed, fontWeight: FontWeight.w700)),
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
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _kBorder),
        ),
        title: Text(
          s.set_name_title,
          style: const TextStyle(
              color: _kTextPrimary, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          style: const TextStyle(color: _kTextPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle: TextStyle(color: _kTextSecondary.withAlpha(160)),
            counterStyle: TextStyle(color: _kTextSecondary.withAlpha(120)),
            filled: true,
            fillColor: _kSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _kBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _kBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _kAmber),
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
            child: Text(s.cancel,
                style: const TextStyle(color: _kTextSecondary)),
          ),
          TextButton(
            onPressed: () {
              context.read<WalkieTalkieCubit>().setMyName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: Text(s.save,
                style: const TextStyle(
                    color: _kAmber, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _RadioIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: _kAmber.withAlpha(30),
        shape: BoxShape.circle,
        border: Border.all(color: _kAmber.withAlpha(80), width: 1),
      ),
      child: const Icon(Icons.radio, color: _kAmber, size: 14),
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
        color: _kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kBorder, width: 1.5),
      ),
      child: child,
    );
  }
}

class _AvatarWidget extends StatelessWidget {
  final String name;
  final bool isActive;
  final double size;

  const _AvatarWidget({
    required this.name,
    required this.isActive,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _kAmber.withAlpha(30),
        border: Border.all(
          color: isActive ? _kAmber.withAlpha(180) : _kBorder,
          width: 1.5,
        ),
        boxShadow: isActive
            ? [BoxShadow(color: _kAmber.withAlpha(60), blurRadius: 12)]
            : null,
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: _kAmber,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final String? badge;

  const _SectionHeader({required this.label, this.badge});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
            width: 3,
            height: 14,
            color: _kAmber,
            margin: const EdgeInsetsDirectional.only(end: 8)),
        Text(
          label,
          style: const TextStyle(
            color: _kTextSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: badge != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, animation) => ScaleTransition(
                          scale: animation,
                          child:
                              FadeTransition(opacity: animation, child: child)),
                      child: Container(
                        key: ValueKey(badge),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _kAmber.withAlpha(40),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            color: _kAmber,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  final ChannelUser user;
  final Animation<double> pulseAnimation;

  const _UserTile({required this.user, required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    final isTalking = user.isTalking;
    final s = context.getString;
    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (_, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isTalking ? _kGreen.withAlpha(15) : _kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isTalking
                ? Color.lerp(
                    _kGreen, _kGreen.withAlpha(80), pulseAnimation.value)!
                : _kBorder,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            _AvatarWidget(
                name: user.name, isActive: isTalking, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.ip.localized(context),
                    style: const TextStyle(
                      color: _kTextSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (isTalking) ...[
              _WaveformBars(animation: pulseAnimation),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _kGreen.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _kGreen.withAlpha(100)),
                ),
                child: Text(
                  s.tx_label,
                  style: const TextStyle(
                    color: _kGreen,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ] else
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _kBorder.withAlpha(80),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  s.user_idle,
                  style: const TextStyle(
                    color: _kTextSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WaveformBars extends StatelessWidget {
  final Animation<double> animation;
  const _WaveformBars({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (i) {
          final height = 6.0 + sin(animation.value * pi + i * 1.2) * 6;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 3,
              height: height.abs() + 2,
              decoration: BoxDecoration(
                color: _kGreen,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _VoxMeter extends StatelessWidget {
  final double rms;
  final double threshold;

  const _VoxMeter({required this.rms, required this.threshold});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isActive = rms > threshold;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              s.level_label,
              style: TextStyle(
                  color: _kTextSecondary.withAlpha(160),
                  fontSize: 10,
                  letterSpacing: 1),
            ),
            const Spacer(),
            Text(
              isActive ? s.level_active : s.level_silent,
              style: TextStyle(
                color: isActive ? _kRed : _kTextSecondary.withAlpha(100),
                fontSize: 10,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) {
            final isRtl = Directionality.of(context) == TextDirection.rtl;
            final w = constraints.maxWidth;
            final rmsNorm = (rms / 0.15).clamp(0.0, 1.0);
            final threshNorm = (threshold / 0.15).clamp(0.0, 1.0);

            // In RTL, bar grows from the right (start) and the threshold
            // marker is mirrored — both computed as explicit left offsets.
            final barLeft = isRtl ? w * (1.0 - rmsNorm) : 0.0;
            final markerLeft = (isRtl
                    ? w * (1.0 - threshNorm) - 1.0
                    : w * threshNorm - 1.0)
                .clamp(0.0, w - 2.0);

            return Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: _kBorder,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Positioned(
                  left: barLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 50),
                    width: w * rmsNorm,
                    height: 8,
                    decoration: BoxDecoration(
                      color: isActive ? _kRed : _kAmberDim,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                  color: _kRed.withAlpha(150), blurRadius: 6)
                            ]
                          : null,
                    ),
                  ),
                ),
                Positioned(
                  left: markerLeft,
                  child: Container(
                    width: 2,
                    height: 8,
                    color: _kTextPrimary.withAlpha(200),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ScanlineBackground extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ScanlinePainter(),
      size: Size.infinite,
    );
  }
}

class _ScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1A2035).withAlpha(80)
      ..strokeWidth = 1;

    for (double y = 0; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
