import 'package:flutter/material.dart';

import '../../domain/entity/room.dart';

/// Read-only durable Room lobby shown before a live transport is started.
///
/// This widget has no transport dependency by design. Its only action is the
/// explicit [onStartRide] handoff owned by the app composition root.
class SelectedRoomLobby extends StatelessWidget {
  const SelectedRoomLobby({
    required this.room,
    required this.onStartRide,
    super.key,
  });

  final SavedRoom room;
  final VoidCallback onStartRide;

  @override
  Widget build(BuildContext context) {
    final fa =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
    final members = room.room.members
        .where((member) => member.isActive)
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: Text(room.room.name)),
      body: SafeArea(
        child: ListView(
          key: const Key('selected-room-lobby'),
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              fa ? 'آماده شروع ارتباط' : 'Ready to start',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
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
                    ? 'اعضای اتاق (${members.length})'
                    : 'Room members (${members.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            for (final member in members)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(
                  member.displayName.trim().isEmpty
                      ? (fa ? 'عضو اتاق' : 'Room member')
                      : member.displayName,
                ),
                subtitle: member.id == room.membership.localMemberId
                    ? Text(fa ? 'شما' : 'You')
                    : null,
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('selected-room-start-ride'),
              onPressed: onStartRide,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(fa ? 'شروع ارتباط' : 'Start ride'),
            ),
          ],
        ),
      ),
    );
  }
}
