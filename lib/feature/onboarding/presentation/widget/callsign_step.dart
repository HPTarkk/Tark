import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../manager/onboarding_cubit.dart';
import 'onboarding_emblem.dart';

/// Beat 2 — pick a callsign. The avatar is a live preview: it takes the
/// name's first letter as you type, and once the name is valid it starts
/// pinging — an expanding radar ring announcing the new operator.
class CallsignStep extends StatefulWidget {
  final Animation<double> reveal;

  /// 0..1 sawtooth loop driving the avatar's radar ping.
  final Animation<double> ping;

  /// Called on keyboard "done" with a valid name — advances the journey.
  final VoidCallback onSubmit;

  const CallsignStep({
    super.key,
    required this.reveal,
    required this.ping,
    required this.onSubmit,
  });

  @override
  State<CallsignStep> createState() => _CallsignStepState();
}

class _CallsignStepState extends State<CallsignStep> {
  late final TextEditingController _controller;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<OnboardingCubit>().state.name,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The gamified escape hatch for name-picker paralysis: rolls a radio
  /// handle from a localized pool plus a two-digit unit number (Persian
  /// digits under fa, so no bidi reordering inside the name).
  void _shuffle() {
    final pool = context.getString.onboarding_callsign_pool.split(',');
    final word = pool[_rng.nextInt(pool.length)].trim();
    final number = (10 + _rng.nextInt(90)).localized(context);
    final name = '$word$number';
    HapticFeedback.selectionClick();
    Sfx.play(SfxEvent.toggle);
    _controller.text = name;
    context.read<OnboardingCubit>().setName(name);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    // The cubit pre-fills the saved name asynchronously (see its _init);
    // mirror that into the field if it lands after this widget built.
    return BlocListener<OnboardingCubit, OnboardingState>(
      listenWhen: (p, c) => p.name != c.name && c.name != _controller.text,
      listener: (_, state) => _controller.text = state.name,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StaggeredItem(
            reveal: widget.reveal,
            index: 0,
            count: 4,
            child: Text(
              s.onboarding_callsign_title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 24),
          StaggeredItem(
            reveal: widget.reveal,
            index: 1,
            count: 4,
            child: Center(
              child: BlocBuilder<OnboardingCubit, OnboardingState>(
                buildWhen: (p, c) => p.name != c.name,
                builder: (_, state) {
                  final valid = state.name.trim().isNotEmpty;
                  return SizedBox(
                    width: 120,
                    height: 120,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (valid)
                          AnimatedBuilder(
                            animation: widget.ping,
                            builder: (_, _) => CustomPaint(
                              size: const Size(120, 120),
                              painter: _PingPainter(
                                t: widget.ping.value,
                                color: AppColors.amber,
                              ),
                            ),
                          ),
                        AppAvatar(
                          name: state.name.trim(),
                          size: 72,
                          isActive: valid,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 20),
          StaggeredItem(
            reveal: widget.reveal,
            index: 2,
            count: 4,
            child: TextField(
              controller: _controller,
              maxLength: 20,
              textAlign: TextAlign.center,
              textInputAction: TextInputAction.done,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
              cursorColor: AppColors.amber,
              decoration: InputDecoration(
                hintText: s.name_hint,
                hintStyle: TextStyle(
                  color: AppColors.textSecondary.withAlpha(140),
                  fontWeight: FontWeight.w400,
                ),
                counterStyle: TextStyle(
                  color: AppColors.textSecondary.withAlpha(120),
                  fontSize: 10,
                ),
                filled: true,
                fillColor: AppColors.card,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                suffixIcon: IconButton(
                  onPressed: _shuffle,
                  icon: Icon(
                    Icons.casino_rounded,
                    color: AppColors.amber,
                    size: 20,
                  ),
                ),
                // Mirror the die so the centered text stays optically
                // centered despite the suffix affordance.
                prefixIcon: const SizedBox(width: 48),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.amber, width: 1.5),
                ),
              ),
              onChanged: context.read<OnboardingCubit>().setName,
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) widget.onSubmit();
              },
            ),
          ),
          const SizedBox(height: 6),
          StaggeredItem(
            reveal: widget.reveal,
            index: 3,
            count: 4,
            child: Text(
              s.onboarding_callsign_help,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary.withAlpha(180),
                fontSize: 11.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Radar ping around the avatar: one ring per cycle expanding from the
/// avatar's edge and fading out — "you're on the map now".
class _PingPainter extends CustomPainter {
  final double t;
  final Color color;

  const _PingPainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final eased = Curves.easeOut.transform(t);
    final radius = 38 + (size.width / 2 - 38) * eased;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withAlpha(((1 - t) * (1 - t) * 130).toInt()),
    );
  }

  @override
  bool shouldRepaint(_PingPainter old) => old.t != t || old.color != color;
}
