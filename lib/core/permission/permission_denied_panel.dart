import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import 'permission_illustration.dart';
import 'permission_kind.dart';

/// The in-place "this permission is off" state, for a screen that cannot do
/// its job without it — the QR scanner with no camera, say.
///
/// The same scene as the primer, settled: it arrives alive and comes to rest,
/// so the screen says *paused* rather than *broken*. One clear action brings
/// the primer back, which itself knows whether to ask again or to send the
/// person to the system settings.
class PermissionDeniedPanel extends StatelessWidget {
  const PermissionDeniedPanel({
    required this.kind,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.palette,
    super.key,
  });

  final PermissionKind kind;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  /// A fixed palette, for surfaces that do not follow the theme (the camera
  /// is always black).
  final AppPalette? palette;

  @override
  Widget build(BuildContext context) {
    final p = palette ?? AppColors.palette;
    final accent = kind.accentOn(p);
    final onAccent = ForestPalette.of(p).onAccent;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: StaggeredEntrance(
            builder: (context, children) =>
                Column(mainAxisSize: MainAxisSize.min, children: children),
            children: [
              PermissionIllustration(
                kind: kind,
                denied: true,
                height: 150,
                palette: palette,
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 13.5,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 22),
              Semantics(
                button: true,
                label: actionLabel,
                child: ExcludeSemantics(
                  child: PressableScale(
                    key: const Key('permission-denied-panel-action'),
                    onTap: onAction,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      height: 50,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(kind.icon, size: 20, color: onAccent),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              actionLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: onAccent,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
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
