import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import '../widget/sheet_shell.dart';
import 'permission_flow.dart';
import 'permission_illustration.dart';
import 'permission_kind.dart';

/// Shows [flow] as the primer sheet and completes once the flow has ended —
/// granted (after its success beat), dismissed, or the sheet swiped away,
/// which counts as "not now".
Future<void> showPermissionPrimerSheet(
  BuildContext context,
  PermissionFlowController flow,
) async {
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    routeSettings: const RouteSettings(name: 'PermissionPrimer'),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => PermissionPrimerSheet(flow: flow),
  );
  flow.notNow();
}

/// The copy for one [PermissionKind].
class PermissionCopy {
  const PermissionCopy({
    required this.label,
    required this.title,
    required this.body,
    required this.promise,
    required this.denied,
  });

  /// The permission's everyday name — the eyebrow, and what to look for in
  /// the system settings.
  final String label;
  final String title;
  final String body;

  /// One short reassurance, the thing people actually worry about.
  final String promise;

  /// What still works without it, and that it can be switched on later.
  final String denied;

  factory PermissionCopy.of(AppLocalizations s, PermissionKind kind) =>
      switch (kind) {
        PermissionKind.microphone => PermissionCopy(
          label: s.perm_mic_label,
          title: s.perm_mic_title,
          body: s.perm_mic_body,
          promise: s.perm_mic_promise,
          denied: s.perm_mic_denied,
        ),
        PermissionKind.camera => PermissionCopy(
          label: s.perm_camera_label,
          title: s.perm_camera_title,
          body: s.perm_camera_body,
          promise: s.perm_camera_promise,
          denied: s.perm_camera_denied,
        ),
        PermissionKind.nearbyDevices => PermissionCopy(
          label: s.perm_nearby_label,
          title: s.perm_nearby_title,
          body: s.perm_nearby_body,
          promise: s.perm_nearby_promise,
          denied: s.perm_nearby_denied,
        ),
        PermissionKind.nearbyWifi => PermissionCopy(
          label: s.perm_wifi_label,
          title: s.perm_wifi_title,
          body: s.perm_wifi_body,
          promise: s.perm_wifi_promise,
          denied: s.perm_wifi_denied,
        ),
        PermissionKind.location => PermissionCopy(
          label: s.perm_location_label,
          title: s.perm_location_title,
          body: s.perm_location_body,
          promise: s.perm_location_promise,
          denied: s.perm_location_denied,
        ),
        PermissionKind.notifications => PermissionCopy(
          label: s.perm_notif_label,
          title: s.perm_notif_title,
          body: s.perm_notif_body,
          promise: s.perm_notif_promise,
          denied: s.perm_notif_denied,
        ),
      };
}

/// The primer itself: scene on top, the words under it, the choice at the
/// bottom. One sheet carries the whole flow — the explanation, the wait while
/// Android's dialog is up, a refusal, the trip to Settings and the grant — so
/// the scene above can *morph* between them instead of being swapped out.
class PermissionPrimerSheet extends StatefulWidget {
  const PermissionPrimerSheet({required this.flow, super.key});

  final PermissionFlowController flow;

  @override
  State<PermissionPrimerSheet> createState() => _PermissionPrimerSheetState();
}

class _PermissionPrimerSheetState extends State<PermissionPrimerSheet>
    with WidgetsBindingObserver {
  PermissionFlowController get _flow => widget.flow;
  Timer? _closeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _flow.addListener(_onFlow);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flow.removeListener(_onFlow);
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings (or from Android's own dialog, which
    // hands the app back the same way): anything switched on there is
    // picked up without the person having to say so.
    if (state == AppLifecycleState.resumed) unawaited(_flow.recheck());
  }

  void _onFlow() {
    if (!mounted) return;
    setState(() {});
    switch (_flow.phase) {
      case PermissionFlowPhase.granted:
        HapticFeedback.lightImpact();
        // The success beat: long enough for the tick to land and be read,
        // then the original action carries on by itself.
        _closeTimer ??= Timer(AppMotion.successBeat, _close);
      case PermissionFlowPhase.dismissed:
        _close();
      case PermissionFlowPhase.denied:
      case PermissionFlowPhase.blocked:
        HapticFeedback.selectionClick();
      default:
        break;
    }
  }

  void _close() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent ?? false) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final kind = _flow.visualKind;
    final accent = kind.accent;
    final forest = AppColors.forest;
    final copy = PermissionCopy.of(s, kind);
    final phase = _flow.phase;
    final settled =
        phase == PermissionFlowPhase.denied ||
        phase == PermissionFlowPhase.blocked ||
        phase == PermissionFlowPhase.settings;
    final granted = phase == PermissionFlowPhase.granted;
    final ltr = Directionality.of(context) == TextDirection.ltr;

    final (String title, String body) = switch (phase) {
      PermissionFlowPhase.granted => (
        s.perm_granted_title,
        s.perm_granted_body,
      ),
      PermissionFlowPhase.denied => (s.perm_denied_title, copy.denied),
      PermissionFlowPhase.blocked || PermissionFlowPhase.settings => (
        s.perm_blocked_title,
        s.perm_blocked_body(copy.label),
      ),
      _ => (copy.title, copy.body),
    };

    final String? note = switch (phase) {
      PermissionFlowPhase.settings => s.perm_waiting,
      PermissionFlowPhase.primer when _flow.blockedAtStart =>
        s.perm_blocked_note,
      _ => null,
    };

    return SheetShell(
      topFraction: 0.1,
      // The website's forest rather than the graphite every other sheet
      // wears: asking for something is the one moment the app should feel
      // like the calm, outdoorsy place the site promised.
      surfaceColor: forest.surface,
      borderColor: accent.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
        child: StaggeredEntrance(
          builder: (context, children) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
          children: [
            _Stage(
              accent: accent,
              child: PermissionIllustration(
                key: const Key('permission-primer-illustration'),
                kind: kind,
                denied: settled,
                granted: granted,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              copy.label.toUpperCase(),
              style: TextStyle(
                color: accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                // Tracking breaks Persian joining; only Latin gets it.
                letterSpacing: ltr ? 2 : 0,
              ),
            ),
            const SizedBox(height: 6),
            PhaseSwitcher(
              alignment: AlignmentDirectional.topStart,
              child: Column(
                key: ValueKey('perm-text-${phase.name}-${kind.name}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    key: const Key('permission-primer-title'),
                    style: TextStyle(
                      color: forest.textPrimary,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    body,
                    style: TextStyle(
                      color: forest.textSecondary,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            // On the grant, the promise and the buttons fold away together:
            // there is nothing left to decide, and the sheet settles around
            // the tick for its beat before it leaves.
            AnimatedSize(
              duration: AppMotion.sheet,
              curve: AppMotion.drawer,
              alignment: Alignment.topCenter,
              child: granted
                  ? const SizedBox(width: double.infinity, height: 8)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 14),
                        AnimatedSwitcher(
                          duration: AppMotion.card,
                          switchInCurve: AppMotion.easeOut,
                          switchOutCurve: AppMotion.leaving,
                          child: _Promise(
                            key: ValueKey('promise-${note ?? copy.promise}'),
                            text: note ?? copy.promise,
                            icon: note != null
                                ? Icons.settings_rounded
                                : Icons.verified_user_rounded,
                            accent: note != null
                                ? forest.textSecondary
                                : accent,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _Actions(flow: _flow, accent: accent),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The scene's backdrop: a card washed with the permission's own colour.
class _Stage extends StatelessWidget {
  const _Stage({required this.accent, required this.child});

  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: AppMotion.sheet,
    curve: AppMotion.easeOut,
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      gradient: RadialGradient(
        radius: 0.95,
        colors: [
          accent.withValues(alpha: 0.12),
          AppColors.forest.card.withValues(alpha: 0.6),
        ],
      ),
      border: Border.all(color: accent.withValues(alpha: 0.16)),
    ),
    child: child,
  );
}

class _Promise extends StatelessWidget {
  const _Promise({
    required this.text,
    required this.icon,
    required this.accent,
    super.key,
  });

  final String text;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: accent.withValues(alpha: 0.22)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.forest.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Actions extends StatelessWidget {
  const _Actions({required this.flow, required this.accent});

  final PermissionFlowController flow;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final phase = flow.phase;
    final (
      String? label,
      IconData icon,
      VoidCallback? action,
    ) = switch (phase) {
      PermissionFlowPhase.primer when flow.blockedAtStart => (
        s.perm_open_settings,
        Icons.settings_rounded,
        () => unawaited(flow.openSettings()),
      ),
      PermissionFlowPhase.primer => (
        s.perm_allow,
        flow.visualKind.icon,
        () => unawaited(flow.allow()),
      ),
      // Android's dialog is up over the sheet; the button holds its
      // place, quietly, until it answers.
      PermissionFlowPhase.requesting => (
        s.perm_allow,
        flow.visualKind.icon,
        null,
      ),
      PermissionFlowPhase.denied => (
        s.perm_try_again,
        Icons.refresh_rounded,
        () => unawaited(flow.retry()),
      ),
      PermissionFlowPhase.blocked || PermissionFlowPhase.settings => (
        s.perm_open_settings,
        Icons.settings_rounded,
        () => unawaited(flow.openSettings()),
      ),
      _ => (null, Icons.check_rounded, null),
    };

    final showNotNow = phase != PermissionFlowPhase.granted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSwitcher(
          duration: AppMotion.card,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
              child: child,
            ),
          ),
          child: label == null
              ? const SizedBox(height: 52, width: double.infinity)
              : _PrimaryButton(
                  key: ValueKey('perm-primary-$label'),
                  label: label,
                  icon: icon,
                  accent: accent,
                  onTap: action,
                ),
        ),
        const SizedBox(height: 6),
        AnimatedOpacity(
          duration: AppMotion.card,
          opacity: showNotNow ? 1 : 0,
          child: TextButton(
            key: const Key('permission-primer-not-now'),
            onPressed: showNotNow ? flow.notNow : null,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.forest.textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(
              s.perm_not_now,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.accent,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    // Text on the filled accent: forest ink on the bright dark-theme
    // accents, paper on the deep light-theme ones — AA on every one.
    final onAccent = AppColors.forest.onAccent;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: ExcludeSemantics(
        child: PressableScale(
          key: const Key('permission-primer-primary'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedOpacity(
            duration: AppMotion.chip,
            opacity: enabled ? 1 : 0.55,
            child: Container(
              height: 52,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: onAccent),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
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
    );
  }
}
