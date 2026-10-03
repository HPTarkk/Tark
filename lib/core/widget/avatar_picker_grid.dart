import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../motion/app_motion.dart';
import '../profile/avatar_catalog.dart';

/// The grid of predefined avatars, shared by the setup step and the Profile
/// page. Each tile is the avatar in a ring that lights up in [accent] and
/// grows a check when selected.
class AvatarPickerGrid extends StatelessWidget {
  const AvatarPickerGrid({
    super.key,
    required this.selectedId,
    required this.onSelected,
    required this.accent,
    required this.idleRing,
    this.columns = 4,
    this.spacing = 12,
  });

  final int? selectedId;
  final ValueChanged<int> onSelected;
  final Color accent;
  final Color idleRing;
  final int columns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tile = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final avatar in AvatarCatalog.all)
              SizedBox.square(
                dimension: tile,
                child: _AvatarTile(
                  avatar: avatar,
                  selected: avatar.id == selectedId,
                  accent: accent,
                  idleRing: idleRing,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onSelected(avatar.id);
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.avatar,
    required this.selected,
    required this.accent,
    required this.idleRing,
    required this.onTap,
  });

  final AvatarDef avatar;
  final bool selected;
  final Color accent;
  final Color idleRing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        key: ValueKey('avatar-${avatar.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedScale(
          scale: selected ? 1.0 : 0.9,
          duration: reduced ? Duration.zero : AppMotion.card,
          curve: Curves.easeOutBack,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: AnimatedContainer(
                  duration: reduced ? Duration.zero : AppMotion.card,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? accent : idleRing,
                      width: selected ? 3 : 1.5,
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: accent.withAlpha(90),
                              blurRadius: 14,
                            ),
                          ]
                        : null,
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      avatar.asset,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                end: -2,
                bottom: -2,
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: reduced ? Duration.zero : AppMotion.card,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
