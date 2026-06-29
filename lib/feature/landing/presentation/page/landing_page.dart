import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/locale/locale_service.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/version_badge.dart';
import '../../../../feature/walkie/presentation/page/walkie_talkie_page.dart';
import '../manager/landing_cubit.dart';

const _kBg = Color(0xFF080B14);
const _kSurface = Color(0xFF0F1320);
const _kCard = Color(0xFF141929);
const _kBorder = Color(0xFF1E2845);
const _kAmber = Color(0xFFFFB74D);
const _kRed = Color(0xFFEF5350);
const _kTextPrimary = Color(0xFFECEFF1);
const _kTextSecondary = Color(0xFF78909C);

class LandingPage extends StatefulWidget {
  static const path = '/';
  static const name = 'LandingPage';

  const LandingPage._();

  static Widget buildPage() => BlocProvider<LandingCubit>(
        create: (_) => LandingCubit(),
        child: const LandingPage._(),
      );

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage>
    with TickerProviderStateMixin {
  // Breathing glow on the logo
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Staggered entrance for all sections
  late AnimationController _entranceController;
  late List<Animation<double>> _sections; // [logo, card, btn, lang, footer]

  // Rotating radar ring behind logo
  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation =
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut);

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    const starts = [0.0, 0.18, 0.34, 0.50, 0.65];
    _sections = starts
        .map((s) => CurvedAnimation(
              parent: _entranceController,
              curve: Interval(s, (s + 0.40).clamp(0.0, 1.0),
                  curve: Curves.easeOutCubic),
            ))
        .toList();

    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _entranceController.forward());
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _radarController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  Widget _entrance(int index, Widget child) => AnimatedBuilder(
        animation: _sections[index],
        builder: (_, _) => Opacity(
          opacity: _sections[index].value,
          child: Transform.translate(
            offset: Offset(0, 28 * (1 - _sections[index].value)),
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
        body: BlocBuilder<LandingCubit, LandingState>(
          builder: (context, state) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  _entrance(0, _buildLogo(context)),
                  const Spacer(flex: 2),
                  _entrance(1, _buildIdentityCard(context, state)),
                  const SizedBox(height: 20),
                  _entrance(2, _buildJoinButton(context, state)),
                  const SizedBox(height: 20),
                  _entrance(3, _buildLanguageToggle(context)),
                  const Spacer(flex: 1),
                  _entrance(4, _buildFooter(context)),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Logo ────────────────────────────────────────────────────────────────────
  Widget _buildLogo(BuildContext context) {
    final s = context.getString;
    return Column(
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([_pulseAnimation, _radarController]),
          builder: (_, child) => Stack(
            alignment: Alignment.center,
            children: [
              // Rotating radar arc
              Transform.rotate(
                angle: _radarController.value * 2 * pi,
                child: CustomPaint(
                  size: const Size(130, 130),
                  painter: _RadarPainter(
                      sweep: _pulseAnimation.value, color: _kAmber),
                ),
              ),
              // Outer pulsing ring
              Container(
                width: 110 + 6 * _pulseAnimation.value,
                height: 110 + 6 * _pulseAnimation.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _kAmber
                        .withAlpha((30 + 50 * _pulseAnimation.value).toInt()),
                    width: 1,
                  ),
                ),
              ),
              // Core circle
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _kCard,
                  border: Border.all(
                    color: _kAmber.withAlpha(
                        (80 + 80 * _pulseAnimation.value).toInt()),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _kAmber.withAlpha(
                          (30 + 70 * _pulseAnimation.value).toInt()),
                      blurRadius: 28 + 14 * _pulseAnimation.value,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: child,
              ),
            ],
          ),
          child: const Icon(Icons.radio, color: _kAmber, size: 48),
        ),
        const SizedBox(height: 20),
        Text(
          s.app_name,
          style: const TextStyle(
            color: _kAmber,
            fontSize: 30,
            fontWeight: FontWeight.w900,
            letterSpacing: 6,
          ),
        ),
        const SizedBox(height: 6),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            s.app_subtitle,
            style: TextStyle(
              color: _kTextSecondary.withAlpha(160),
              fontSize: 11,
              letterSpacing: 4,
              fontWeight: FontWeight.w600,
              fontFamily: null,
            ),
          ),
        ),
      ],
    );
  }

  // ── Identity Card ───────────────────────────────────────────────────────────
  Widget _buildIdentityCard(BuildContext context, LandingState state) {
    final s = context.getString;
    final hasNetwork = state.hasNetwork;
    final displayIp = state.isLoading
        ? s.connecting
        : (hasNetwork ? state.localIp.localized(context) : s.no_network);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kBorder, width: 1.5),
      ),
      child: Row(
        children: [
          _AvatarWidget(name: state.myName, size: 50),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.myName.isEmpty ? '...' : state.myName,
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => ScaleTransition(
                          scale: anim,
                          child: FadeTransition(opacity: anim, child: child)),
                      child: Icon(
                        hasNetwork
                            ? Icons.router_rounded
                            : Icons.wifi_off_rounded,
                        key: ValueKey(hasNetwork),
                        color: hasNetwork ? _kTextSecondary : _kRed,
                        size: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          displayIp,
                          key: ValueKey(displayIp),
                          style: TextStyle(
                            color: hasNetwork ? _kTextSecondary : _kRed,
                            fontSize: 12,
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
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => _showEditNameDialog(context, state.myName),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _kBorder,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit_rounded, color: _kAmber, size: 14),
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
    );
  }

  // ── Join Button ─────────────────────────────────────────────────────────────
  Widget _buildJoinButton(BuildContext context, LandingState state) {
    final enabled = state.hasNetwork && !state.isLoading;
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, child) => GestureDetector(
        onTap: enabled ? () => context.pushNamed(WalkieTalkiePage.name) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: enabled ? _kAmber.withAlpha(25) : _kBorder.withAlpha(40),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: enabled
                  ? Color.lerp(
                      _kAmber, _kAmber.withAlpha(120), _pulseAnimation.value)!
                  : _kBorder,
              width: 2,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: _kAmber.withAlpha(
                          (15 + 40 * _pulseAnimation.value).toInt()),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: child!,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.podcasts_rounded,
            color: state.hasNetwork ? _kAmber : _kTextSecondary,
            size: 22,
          ),
          const SizedBox(width: 12),
          Text(
            context.getString.join_channel,
            style: TextStyle(
              color: state.hasNetwork ? _kAmber : _kTextSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }

  // ── Language Toggle ─────────────────────────────────────────────────────────
  Widget _buildLanguageToggle(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: LocaleService.locale,
      builder: (_, currentLocale, _) => Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LanguageButton(
              label: 'فارسی',
              locale: const Locale('fa'),
              isSelected: currentLocale.languageCode == 'fa',
            ),
            const SizedBox(width: 12),
            _LanguageButton(
              label: 'English',
              locale: const Locale('en'),
              isSelected: currentLocale.languageCode == 'en',
            ),
          ],
        ),
      ),
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────────────
  Widget _buildFooter(BuildContext context) {
    return VersionBadge(color: _kTextSecondary.withAlpha(70));
  }

  // ── Edit name dialog ────────────────────────────────────────────────────────
  void _showEditNameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    final cubit = context.read<LandingCubit>();
    final s = context.getString;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _kBorder),
        ),
        title: Text(s.set_name_title,
            style: const TextStyle(
                color: _kTextPrimary, fontWeight: FontWeight.w700)),
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
            cubit.setMyName(v);
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
              cubit.setMyName(controller.text);
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

// ── Radar sweep painter ──────────────────────────────────────────────────────
class _RadarPainter extends CustomPainter {
  final double sweep;
  final Color color;
  const _RadarPainter({required this.sweep, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          color.withAlpha(0),
          color.withAlpha((60 * sweep).toInt()),
          color.withAlpha(0),
        ],
        stops: const [0.0, 0.25, 0.5],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.sweep != sweep || old.color != color;
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────
class _AvatarWidget extends StatelessWidget {
  final String name;
  final double size;
  const _AvatarWidget({required this.name, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _kAmber.withAlpha(30),
        border: Border.all(color: _kAmber.withAlpha(180), width: 1.5),
        boxShadow: [BoxShadow(color: _kAmber.withAlpha(60), blurRadius: 12)],
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

class _LanguageButton extends StatelessWidget {
  final String label;
  final Locale locale;
  final bool isSelected;
  const _LanguageButton({
    required this.label,
    required this.locale,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => LocaleService.setLocale(locale),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? _kAmber.withAlpha(25) : _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? _kAmber : _kBorder,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? _kAmber : _kTextSecondary,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
