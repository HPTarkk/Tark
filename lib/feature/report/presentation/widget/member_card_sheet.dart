import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../domain/listener_mutes.dart';
import '../../domain/member_tap_hint.dart';
import '../../../../core/profile/avatar_catalog.dart';
import '../../../../core/profile/local_profile.dart';
import '../member_subject.dart';
import 'avatar_images.dart';
import 'report_story_sheet.dart';

/// Opens [subject]'s card: who they are, and the two things a listener can do
/// about them on their own (mute, report).
Future<void> showMemberCard(
  BuildContext context, {
  required MemberSubject subject,
  Widget? status,
  ListenerMutes? mutes,
  Future<bool> Function(Uri uri)? launchMail,
}) async {
  final registry = mutes ?? ListenerMutes.instance;
  unawaited(registry.load());
  // They found it: the roster can stop showing them how.
  unawaited(MemberTapHint.instance.learned());
  // Decoded now, so the report story's cast is ready if they go on to it.
  unawaited(
    AvatarImages.load(LocalProfile.avatarId ?? AvatarCatalog.defaultId),
  );
  unawaited(AvatarImages.load(subject.avatarId));
  final report = await showModalBottomSheet<bool>(
    context: context,
    routeSettings: const RouteSettings(name: 'MemberCardSheet'),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) =>
        MemberCardSheet(subject: subject, status: status, mutes: registry),
  );
  if (report != true || !context.mounted) return;
  await showReportStory(
    context,
    subject: subject,
    mutes: registry,
    launchMail: launchMail,
  );
}

/// A member's profile inside a room.
///
/// Their face arrives with a small spring, and a muted badge lands on it when
/// they are muted, so the state is visible on the person rather than only on a
/// switch. "Report" is a full row with its own colour, but sits under mute:
/// muting is the instant, private fix, reporting the considered one.
class MemberCardSheet extends StatelessWidget {
  const MemberCardSheet({
    required this.subject,
    required this.mutes,
    this.status,
    super.key,
  });

  final MemberSubject subject;
  final ListenerMutes mutes;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final reduced = AppMotion.reduced(context);
    return SheetShell(
      topFraction: 0.3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
        child: ListenableBuilder(
          listenable: mutes,
          builder: (context, _) {
            final muted = subject.isMuted(mutes);
            return StaggeredEntrance(
              builder: (context, children) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
              children: [
                Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: reduced ? 1 : 0.6, end: 1),
                    duration: const Duration(milliseconds: 520),
                    curve: Curves.easeOutBack,
                    builder: (context, scale, child) =>
                        Transform.scale(scale: scale, child: child),
                    child: SizedBox(
                      width: 92,
                      height: 92,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          AnimatedOpacity(
                            duration: AppMotion.card,
                            opacity: muted ? 0.6 : 1,
                            child: subject.avatar(92),
                          ),
                          PositionedDirectional(
                            start: -4,
                            bottom: -2,
                            child: _MutedBadge(visible: muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  subject.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(height: 6),
                  Center(child: status),
                ],
                const SizedBox(height: 20),
                if (subject.canMute) ...[
                  _CardAction(
                    key: const Key('member-card-mute'),
                    icon: muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    title: s.member_mute,
                    subtitle: s.member_mute_hint,
                    accent: AppColors.amber,
                    trailing: Switch(
                      value: muted,
                      activeThumbColor: AppColors.amber,
                      onChanged: (value) => _setMuted(value),
                    ),
                    onTap: () => _setMuted(!muted),
                  ),
                  const SizedBox(height: 10),
                ],
                _CardAction(
                  key: const Key('member-card-report'),
                  icon: Icons.flag_rounded,
                  title: s.member_report,
                  subtitle: s.member_report_hint,
                  accent: AppColors.red,
                  // Mirrors itself in RTL (matchTextDirection), so it always
                  // points the way the row reads.
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                  ),
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _setMuted(bool value) {
    HapticFeedback.selectionClick();
    unawaited(subject.setMuted(mutes, value));
  }
}

class _MutedBadge extends StatelessWidget {
  const _MutedBadge({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedScale(
      scale: visible ? 1 : (reduced ? 1 : 0),
      duration: AppMotion.sheet,
      curve: visible ? Curves.easeOutBack : AppMotion.easeOut,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.card,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: AppColors.amber,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.surface, width: 3),
          ),
          child: const Icon(
            Icons.volume_off_rounded,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.trailing,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: AnimatedSwitcher(
                duration: AppMotion.card,
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: AppMotion.leaving,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(icon, key: ValueKey(icon), color: accent, size: 21),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    ),
  );
}
