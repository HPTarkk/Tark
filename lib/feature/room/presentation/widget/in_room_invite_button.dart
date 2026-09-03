import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../domain/repository/room_repository.dart';
import 'room_people_sheet.dart';

/// Opens the Room's people sheet — the roster, and the way to add someone.
///
/// This used to be a bare `person_add` glyph wedged between three other icons
/// in the channel header, which is a hard thing to find and an easy thing to
/// hit by accident. It is now a labelled control carrying the live member
/// count, so the roster is legible without opening anything and "add someone"
/// is a place rather than a guess.
///
/// [compact] renders the pill without its label, for the header on narrow
/// phones where the count still fits but the word does not.
class InRoomInviteButton extends StatefulWidget {
  const InRoomInviteButton({
    super.key,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.compact = false,
  });

  /// Optional seams for deterministic widget tests. Production resolves the
  /// canonical registrations owned by the Room and transfer features.
  final RoomRepository? repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;
  final bool compact;

  @override
  State<InRoomInviteButton> createState() => _InRoomInviteButtonState();
}

class _InRoomInviteButtonState extends State<InRoomInviteButton> {
  RoomRepository? get _repository {
    if (widget.repository != null) return widget.repository;
    return GetIt.instance.isRegistered<RoomRepository>()
        ? GetIt.instance<RoomRepository>()
        : null;
  }

  int? _count;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Reads the confirmed head count.
  ///
  /// Confirmed, never active: an invite that nobody has used holds a durable
  /// seat, and counting those is precisely how one phone came to claim four
  /// people in a room containing two.
  Future<void> _refresh() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final id = await repository.selectedRoomId();
      final saved = id == null ? null : await repository.get(id);
      if (!mounted) return;
      setState(() => _count = saved?.room.confirmedMembers.length);
    } catch (_) {
      // A header badge is not worth surfacing an error for; it simply shows
      // nothing and the sheet behind it still opens.
    }
  }

  Future<void> _open() async {
    HapticFeedback.selectionClick();
    await showRoomPeopleSheet(
      context,
      repository: widget.repository,
      identityLifecycle: widget.identityLifecycle,
      hotspotLinkKeeper: widget.hotspotLinkKeeper,
      transferRepository: widget.transferRepository,
    );
    // The sheet can add or revoke a seat, so the badge re-reads rather than
    // trusting what it showed when it opened.
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _Copy.of(context);
    final count = _count;
    return Semantics(
      button: true,
      label: count == null ? copy.people : copy.peopleCount(count),
      excludeSemantics: true,
      child: Tooltip(
        message: copy.people,
        child: PressableScale(
          onTap: _open,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            key: const Key('in-room-add-rider'),
            height: 34,
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 9 : 11),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: AppColors.amber.withValues(alpha: 0.42),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.group_add_rounded, size: 16, color: AppColors.amber),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    count.localized(context),
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                if (!widget.compact) ...[
                  const SizedBox(width: 6),
                  Text(
                    copy.people,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Copy {
  const _Copy({required this.fa});

  factory _Copy.of(BuildContext context) => _Copy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
  );

  final bool fa;

  String get people => fa ? 'فرد' : 'People';

  String peopleCount(int count) {
    final n = localizeDigits('$count', farsi: fa);
    return fa ? 'افراد اتاق، $n نفر' : 'Room people, $n in the room';
  }
}
