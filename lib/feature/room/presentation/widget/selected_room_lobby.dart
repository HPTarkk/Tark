import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../domain/entity/room.dart';
import '../room_member_display_name.dart';
import 'in_room_invite_button.dart';

/// Read-only durable Room lobby shown before a live transport is started.
///
/// Inviting members remains available before transport starts, keeping logical
/// Room membership separate from Wi-Fi/hotspot setup.
class SelectedRoomLobby extends StatelessWidget {
  const SelectedRoomLobby({
    required this.room,
    required this.onStartRide,
    required this.onBack,
    super.key,
  });

  final SavedRoom room;
  final VoidCallback onStartRide;

  /// The way back out.
  ///
  /// Creating a room lands here by *replacing* the stack, so this screen is
  /// routinely the only route on it and there is no system back to inherit —
  /// Android's back gesture closed the app instead. The caller decides where
  /// "out" is, because only the composition root knows what is underneath.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final fa =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
    // Confirmed, not merely active: a seat held open by an unused invite is
    // durable and authorised but nobody is standing in it, and listing it here
    // is what made two phones disagree about how many people were in the room.
    final members = room.room.confirmedMembers;
    final backLabel = fa ? 'بازگشت' : 'Back';
    return Scaffold(
      appBar: AppBar(
        // Nothing has started here — the screen's own promise is that no
        // hotspot, microphone or transport is running yet — so leaving needs
        // no confirmation. That is the whole difference between this control
        // and the channel's, which wears the same chevron over a question.
        leading: Semantics(
          button: true,
          label: backLabel,
          child: IconButton(
            key: const Key('selected-room-lobby-back'),
            tooltip: backLabel,
            onPressed: () {
              HapticFeedback.selectionClick();
              onBack();
            },
            icon: Icon(
              Icons.arrow_back_rounded,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        title: Text(room.room.name),
        actions: const [InRoomInviteButton()],
      ),
      body: SafeArea(
        // The lobby is the pause before the ride starts, and the one screen in
        // the flow that is purely about reading. Its content arrives in the
        // order it should be read — heading, the promise that nothing has
        // started yet, then the roster, then the action — so the stagger is
        // doing the work a designer would otherwise ask numbering to do.
        child: StaggeredEntrance(
          builder: (context, children) => ListView(
            key: const Key('selected-room-lobby'),
            padding: const EdgeInsets.all(20),
            children: children,
          ),
          children: [
            Text(
              fa ? 'آماده شروع ارتباط' : 'Ready to start',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              fa
                  ? 'تا وقتی «شروع ارتباط» را نزنید، هیچ هات‌اسپات، میکروفن یا اتصال زنده‌ای شروع نمی‌شود.'
                  : 'No hotspot, microphone, or live transport starts until you press Start ride.',
            ),
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(
                fa
                    ? 'اعضای اتاق (${members.length.localized(context)})'
                    : 'Room members (${members.length.localized(context)})',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            for (final member in members)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                // Shared with the People sheet: a seat confirmed from live
                // evidence still carries the "Open seat" placeholder the host
                // wrote into it, and this list is only ever confirmed members.
                title: Text(
                  roomMemberDisplayName(
                    member,
                    fa: fa,
                    unnamed: fa ? 'عضو اتاق' : 'Room member',
                  ),
                ),
                subtitle: member.id == room.membership.localMemberId
                    ? Text(fa ? 'شما' : 'You')
                    : null,
              ),
            const SizedBox(height: 20),
            _StartRideButton(
              key: const Key('selected-room-start-ride'),
              label: fa ? 'شروع ارتباط' : 'Start ride',
              onTap: onStartRide,
            ),
          ],
        ),
      ),
    );
  }
}

/// The one action this screen exists to offer, so it breathes.
///
/// Deliberately not a `FilledButton`: a single gesture owner, so the press
/// settle, the haptic and the callback cannot disagree about who handled the
/// tap — and the amber treatment ties it to the primary action on Landing,
/// which is the same promise one step earlier.
class _StartRideButton extends StatelessWidget {
  const _StartRideButton({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  static final _radius = BorderRadius.circular(14);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: PulseGlow(
      borderRadius: _radius,
      child: PressableScale(
        onTap: onTap,
        borderRadius: _radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.12),
            borderRadius: _radius,
            border: Border.all(color: AppColors.amber, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.play_arrow_rounded, color: AppColors.amber),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
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
