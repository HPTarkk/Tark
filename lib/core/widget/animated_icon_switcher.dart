import 'package:flutter/widgets.dart';

class AnimatedIconSwitcher extends StatelessWidget {
  final Icon firstIcon;
  final Icon secondIcon;
  final bool showFirst;

  const AnimatedIconSwitcher({
    super.key,
    required this.firstIcon,
    required this.secondIcon,
    required this.showFirst,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        final scaleAnimation = Tween<double>(begin: 0.75, end: 1.0).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: scaleAnimation, child: child),
        );
      },
      child: showFirst
          ? Icon(firstIcon.icon, key: const ValueKey('first'), size: firstIcon.size, color: firstIcon.color)
          : Icon(
              secondIcon.icon,
              key: const ValueKey('second'),
              size: secondIcon.size,
              color: secondIcon.color,
            ),
    );
  }
}
