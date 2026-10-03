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

/// The same avatars in one sideways-scrolling row, for screens where the
/// grid would push everything else out of sight. Opens scrolled so the
/// current face is in view, and fades at both ends to show there is more.
class AvatarPickerStrip extends StatefulWidget {
  const AvatarPickerStrip({
    super.key,
    required this.selectedId,
    required this.onSelected,
    required this.accent,
    required this.idleRing,
    this.tile = 58,
    this.spacing = 12,
    this.padding = 16,
  });

  final int? selectedId;
  final ValueChanged<int> onSelected;
  final Color accent;
  final Color idleRing;
  final double tile;
  final double spacing;

  /// Space before the first and after the last face, so the row lines up
  /// with the content around it while still scrolling edge to edge.
  final double padding;

  @override
  State<AvatarPickerStrip> createState() => _AvatarPickerStripState();
}

class _AvatarPickerStripState extends State<AvatarPickerStrip> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Whether the opening scroll to the current face has happened. The saved
  /// face often arrives a moment after the first frame; after the first
  /// reveal, picks are made in view and the row is left where it is.
  bool _revealed = false;

  @override
  void didUpdateWidget(AvatarPickerStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_revealed && oldWidget.selectedId != widget.selectedId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void _reveal() {
    if (!mounted || !_controller.hasClients || _revealed) return;
    final index = AvatarCatalog.all.indexWhere(
      (a) => a.id == widget.selectedId,
    );
    if (index < 0) return;
    _revealed = true;
    final position = _controller.position;
    final step = widget.tile + widget.spacing;
    final centred =
        widget.padding +
        index * step -
        (position.viewportDimension - widget.tile) / 2;
    _controller.jumpTo(
      centred.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The ring and glow spill a little past each tile.
    final height = widget.tile + 12;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0, 0.05, 0.95, 1],
      ).createShader(bounds),
      child: SizedBox(
        height: height,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: widget.padding),
          child: Row(
            children: [
              for (final (i, avatar) in AvatarCatalog.all.indexed) ...[
                if (i > 0) SizedBox(width: widget.spacing),
                SizedBox.square(
                  dimension: widget.tile,
                  child: _AvatarTile(
                    avatar: avatar,
                    selected: avatar.id == widget.selectedId,
                    accent: widget.accent,
                    idleRing: widget.idleRing,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onSelected(avatar.id);
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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
