import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/animations/anc_headset_loop_animation.dart';
import '../../../../core/widget/animations/anc_headset_loop_animation_light.dart';
import '../../../../core/widget/animations/helmet_loop_animation.dart';
import '../../../../core/widget/animations/helmet_loop_animation_light.dart';
import '../../../../core/widget/animations/mic_loop_animation.dart';
import '../../../../core/widget/animations/mic_loop_animation_light.dart';

class _Tip {
  final Widget asset;
  final Widget lightAsset;
  final String title;
  final String body;

  const _Tip({required this.asset, required this.lightAsset, required this.title, required this.body});
}

/// One-time (ever) usage-tips bottom sheet — practical suggestions for a
/// better riding experience, each paired with a small looping animation
/// (hand-authored Lottie for the first two, a custom-painted Flutter widget
/// for the third). Shown once per install; see
/// [SettingsRepository.usageTipsShown] for the persisted flag that guards
/// this.
Future<void> showUsageTipsSheet(BuildContext context) {
  final s = context.getString;
  final tips = [
    _Tip(
      asset: AncHeadsetLoopAnimation(),
      lightAsset: AncHeadsetLoopAnimationLight(),
      title: s.usage_tips_1_title,
      body: s.usage_tips_1_body,
    ),
    _Tip(
      asset: HelmetLoopAnimation(),
      lightAsset: HelmetLoopAnimationLight(),
      title: s.usage_tips_2_title,
      body: s.usage_tips_2_body,
    ),
    _Tip(
      asset: const MicLoopAnimation(),
      lightAsset: const MicLoopAnimationLight(),
      title: s.usage_tips_3_title,
      body: s.usage_tips_3_body,
    ),
  ];

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _UsageTipsSheet(tips: tips),
  );
}

class _UsageTipsSheet extends StatefulWidget {
  final List<_Tip> tips;

  const _UsageTipsSheet({required this.tips});

  @override
  State<_UsageTipsSheet> createState() => _UsageTipsSheetState();
}

class _UsageTipsSheetState extends State<_UsageTipsSheet> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.amber.withAlpha(90)),
          boxShadow: [BoxShadow(color: AppColors.amber.withAlpha(30), blurRadius: 40, spreadRadius: -6)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.usage_tips_title,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 300,
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.tips.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _TipPage(tip: widget.tips[i]),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                widget.tips.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? AppColors.amber : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.amber.withAlpha(140), width: 1.5),
                ),
                child: Text(
                  s.usage_tips_dismiss,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipPage extends StatelessWidget {
  final _Tip tip;

  const _TipPage({required this.tip});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: double.infinity, child: switch (Theme.brightnessOf(context)) {
          Brightness.dark => tip.asset,
          Brightness.light => tip.lightAsset,
        }),
        const SizedBox(height: 8),
        Text(
          tip.title,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            tip.body,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.5),
          ),
        ),
      ],
    );
  }
}
