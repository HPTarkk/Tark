import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/utils/extensions.dart';
import '../../../room/domain/entity/room.dart';
import '../../../room/domain/repository/room_repository.dart';
import 'room_entry_actions.dart';

/// Landing's way into a Room, in whatever shape this phone's storage says.
///
/// The Room is created before a transport is selected, so a Room has a single,
/// obvious home-screen entry rather than being hidden behind Channel. What that
/// entry *says* depends on whether this phone has a Room already: with one
/// saved, the lead action resumes it and the list is one tap away; without one,
/// creating leads.
///
/// It lives here rather than inside the page because it is the one thing on
/// Landing that reads storage, and it has to keep doing so for as long as it is
/// on screen — see [_watch].
class RoomEntryOptions extends StatefulWidget {
  const RoomEntryOptions({super.key, this.repository});

  /// An optional seam for deterministic widget tests. Production resolves the
  /// canonical registration owned by the Room feature, and tolerates its
  /// absence: Landing must open with or without Room storage.
  final RoomRepository? repository;

  @override
  State<RoomEntryOptions> createState() => _RoomEntryOptionsState();
}

class _RoomEntryOptionsState extends State<RoomEntryOptions> {
  List<SavedRoom> _rooms = const [];
  SavedRoom? _selected;
  StreamSubscription<void>? _changes;

  RoomRepository? get _repository {
    if (widget.repository != null) return widget.repository;
    return GetIt.instance.isRegistered<RoomRepository>()
        ? GetIt.instance<RoomRepository>()
        : null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _watch();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Landing sits *under* the room list rather than beside it, and a covered
  /// route is never rebuilt: `didChangeDependencies` does not fire when the
  /// route above pops, which is why deleting a Room over there left this screen
  /// still counting it. So the trigger is the storage that changed, not the
  /// navigation that happened to be how the user came back.
  void _watch() {
    _changes = _repository?.changes.listen((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final rooms = await repository.list();
      final selectedId = await repository.selectedRoomId();
      if (!mounted) return;
      SavedRoom? selected;
      for (final saved in rooms) {
        if (saved.room.id == selectedId) {
          selected = saved;
          break;
        }
      }
      setState(() {
        _rooms = rooms;
        _selected = selected;
      });
    } catch (_) {
      // Landing must open with or without Room storage. Falling through to
      // the first-run shape is honest: it offers create and join, both of
      // which work, rather than claiming a Room we could not read.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.getString;
    final resume = _selected ?? (_rooms.isEmpty ? null : _rooms.first);

    // First run has genuinely two options and no list to browse, so it keeps
    // the full-width pair of rows: a screen with two things on it is not a
    // list, and narrowing them into halves would only make them harder to hit
    // for no gain. Every later run has three, which is where the tiers matter.
    if (resume == null) {
      return RoomEntryActions(
        hero: RoomEntryAction(
          key: const Key('landing-create-room'),
          icon: Icons.add_home_work_outlined,
          label: t.entry_create_room,
          hint: t.entry_create_room_hint,
          variant: RoomEntryVariant.hero,
          onTap: () => context.push('${AppRoutes.roomsPath}?create=true'),
        ),
        alternatives: [
          RoomEntryAction(
            key: const Key('landing-join-room'),
            icon: Icons.qr_code_scanner_rounded,
            label: t.entry_join_qr,
            hint: t.entry_join_qr_hint,
            variant: RoomEntryVariant.wide,
            onTap: () => context.push(AppRoutes.roomQrJoinPath),
          ),
        ],
      );
    }

    return RoomEntryActions(
      // The room's own mark rather than a door glyph: this is the card the
      // user picked it on, one screen earlier.
      hero: RoomEntryAction(
        key: const Key('landing-resume-room'),
        icon: Icons.meeting_room_rounded,
        monogram: resume.room.name,
        label: resume.room.name,
        hint: t.entry_resume_hint,
        variant: RoomEntryVariant.hero,
        onTap: () => context.push(AppRoutes.walkiePath),
      ),
      // Side by side because they are alternatives to *each other* — both are
      // "begin something new". Saying that is what finally gets create out of
      // MY ROOMS' hint text, and it costs no height to say.
      alternatives: [
        RoomEntryAction(
          key: const Key('landing-join-room'),
          icon: Icons.qr_code_scanner_rounded,
          label: t.entry_join,
          hint: t.entry_join_hint,
          variant: RoomEntryVariant.compact,
          onTap: () => context.push(AppRoutes.roomQrJoinPath),
        ),
        RoomEntryAction(
          key: const Key('landing-create-room'),
          // Not a bare `add_rounded`: a thin cross beside the QR glyph's dense
          // frame makes one half of the pair look lighter than the other,
          // which is the one thing this row must not say.
          icon: Icons.add_circle_outline_rounded,
          label: t.entry_new_room,
          hint: t.entry_new_room_hint,
          variant: RoomEntryVariant.compact,
          onTap: () => context.push('${AppRoutes.roomsPath}?create=true'),
        ),
      ],
      browse: RoomBrowseLink(
        key: const Key('landing-all-rooms'),
        label: t.entry_my_rooms,
        count: _rooms.length.localized(context),
        onTap: () => context.push(AppRoutes.roomsPath),
      ),
    );
  }
}
