import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../domain/entity/room.dart';
import '../../domain/repository/room_repository.dart';
import 'room_people_sheet.dart';

/// The way into the Room's people sheet from the channel screen.
///
/// R32. This used to be a pill in the channel header, holding the trailing
/// edge of the one screen a rider looks at for a whole trip — for an act that
/// happens once a ride at most, if at all. It sits in the members card now,
/// where the question "who is here" is already being asked, and it can do
/// something a header pill never could: **be the lit control when the answer
/// is nobody.**
///
/// That is the whole reason this has two weights rather than one appearance.
/// It is the same inversion R24 built for the lobby — a channel with nobody
/// else on it is not a channel yet, so inviting is the thing to press; once
/// somebody is there, inviting is a quiet control under the list and the
/// screen's attention belongs to the mic. Exactly one control glows at a time.
///
/// **It renders nothing without a Room**, in either weight. A plain channel
/// with no durable Room has nothing to invite anyone *into*, and a control
/// that opens a sheet only to explain why it cannot help is worse than no
/// control — the empty-state card keeps its heading and simply stops one line
/// earlier, the way the lobby's callout does without the invite right.
///
/// **An empty channel has two causes and they need opposite offers.** Nobody
/// has joined the room yet — invite them. Or the room is full of people this
/// phone cannot hear, which is the case a link check upstream cannot catch:
/// both phones are on *something*, just not on the same thing, and there is
/// no signal before traffic that can tell "on a network" from "on their
/// network" (see [LiveLink.provesPeer]). Offering a QR code to someone whose
/// friend is already in the room is answering a question they did not ask, so
/// the durable roster decides: with other confirmed members present, getting
/// onto one network leads and inviting steps down.
class InRoomPeopleAction extends StatefulWidget {
  const InRoomPeopleAction({
    super.key,
    required this.primary,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.modeStore,
  });

  /// Lit and leading, or quiet and out of the way. Driven by whether anyone
  /// else is on the channel, which is the only thing that changes the answer
  /// to "is this the thing to press".
  final bool primary;

  /// Optional seams for deterministic widget tests. Production resolves the
  /// canonical registrations owned by the Room and transfer features.
  final RoomRepository? repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;
  final TransferModeStore? modeStore;

  @override
  State<InRoomPeopleAction> createState() => _InRoomPeopleActionState();
}

class _InRoomPeopleActionState extends State<InRoomPeopleAction> {
  RoomRepository? get _repository {
    if (widget.repository != null) return widget.repository;
    return GetIt.instance.isRegistered<RoomRepository>()
        ? GetIt.instance<RoomRepository>()
        : null;
  }

  bool _hasRoom = false;

  /// Whether the durable roster holds anyone besides this phone.
  ///
  /// Confirmed members only. A seat held open by an unused invite is somebody
  /// who has not turned up yet, which is the *inviting* case wearing the
  /// stranded case's clothes — counting it would send a host who has just made
  /// a code to the bridge instead of showing them the code.
  bool _othersInRoom = false;

  /// Whether this phone may issue invites, which is also how it guesses which
  /// side of a bridge it should be.
  bool _canInvite = false;
  StreamSubscription<void>? _changes;

  /// Read for the pin only, and tolerated absent. Nothing here starts, stops
  /// or switches a transport — a hand-picked one just changes which screen
  /// can do anything about the situation.
  TransferModeStore? get _modeStore {
    if (widget.modeStore != null) return widget.modeStore;
    return GetIt.instance.isRegistered<TransferModeStore>()
        ? GetIt.instance<TransferModeStore>()
        : null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // A room can be selected, left or deleted while this card is on screen,
    // and a covered route is never rebuilt — storage is the only thing that
    // knows the answer changed, so storage is what says so (R23).
    _changes = _repository?.changes.listen((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final id = await repository.selectedRoomId();
      final saved = id == null ? null : await repository.get(id);
      if (!mounted) return;
      setState(() {
        _hasRoom = id != null;
        _othersInRoom = saved != null && _others(saved) > 0;
        _canInvite = saved != null && saved.membership.canManageInvites;
      });
    } catch (_) {
      // Nothing here is worth surfacing an error for. Without an answer the
      // control stays hidden, which is the same thing it does with no Room.
    }
  }

  static int _others(SavedRoom saved) => saved.room.confirmedMembers
      .where((member) => member.id != saved.membership.localMemberId)
      .length;

  /// Leaves the channel for the screen that can put these two phones on one
  /// network.
  ///
  /// `go`, not `push`, and that is the important part: this replaces the
  /// channel route, so the session, the microphone and the keep-alive come
  /// down with it exactly as they do on Leave. Pushing would have left the mic
  /// live behind a setup screen.
  ///
  /// No confirmation, unlike Leave. This control only exists on a channel with
  /// nobody on it — there is no call to interrupt, and asking "are you sure"
  /// about abandoning silence is friction charged for nothing.
  void _connect() {
    HapticFeedback.selectionClick();
    context.go(
      ConnectRoute.forStrandedRoom(
        // The same rule the lobby uses: whoever hands out the invite code is
        // the phone the others are gathering around, so it is the one that
        // should be making the network. It only preselects a side the bridge
        // can still step back out of.
        intent: _canInvite ? ChannelIntent.create : ChannelIntent.join,
        pinned: _modeStore?.pinnedMode,
      ),
    );
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
    // The sheet can add or revoke a seat, and leaving from it would drop the
    // room out from under this control.
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasRoom) return const SizedBox.shrink();
    final copy = _Copy.of(context);
    // Quiet weight is the channel with people on it. Nothing is wrong there,
    // so it stays exactly what it was: one small control under the list.
    if (!widget.primary) {
      return _PeopleAction(
        key: const Key('channel-invite-quiet'),
        icon: Icons.person_add_alt_1_rounded,
        label: copy.addSomeone,
        primary: false,
        onTap: _open,
      );
    }
    return Column(
      children: [
        const SizedBox(height: 6),
        Text(
          _othersInRoom ? copy.strandedBody : copy.aloneBody,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        if (_othersInRoom) ...[
          _PeopleAction(
            key: const Key('channel-connect-primary'),
            icon: Icons.wifi_tethering_rounded,
            label: copy.getOnOneNetwork,
            primary: true,
            onTap: _connect,
          ),
          const SizedBox(height: 10),
          // Still offered, quietly: "nobody can hear me" and "I want one more
          // person" are both true often enough that removing the code would
          // trade one dead end for another.
          _PeopleAction(
            key: const Key('channel-invite-quiet'),
            icon: Icons.person_add_alt_1_rounded,
            label: copy.addSomeone,
            primary: false,
            onTap: _open,
          ),
        ] else
          _PeopleAction(
            key: const Key('channel-invite-primary'),
            icon: Icons.qr_code_2_rounded,
            label: copy.inviteSomeone,
            primary: true,
            onTap: _open,
          ),
      ],
    );
  }
}

/// The two weights, drawn the way the lobby draws them.
///
/// Deliberately not a `FilledButton`/`OutlinedButton` pair: a single gesture
/// owner, so the press settle, the haptic and the callback cannot disagree
/// about who handled the tap — and the amber treatment ties this to the same
/// action one screen earlier, which is the same promise.
class _PeopleAction extends StatelessWidget {
  const _PeopleAction({
    required this.icon,
    required this.label,
    required this.primary,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  static final _radius = BorderRadius.circular(14);

  @override
  Widget build(BuildContext context) {
    final accent = primary ? AppColors.amber : AppColors.textSecondary;
    return Semantics(
      button: true,
      label: label,
      child: PulseGlow(
        borderRadius: _radius,
        enabled: primary,
        child: PressableScale(
          onTap: onTap,
          borderRadius: _radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: primary
                  ? AppColors.amber.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: _radius,
              border: Border.all(
                color: primary ? AppColors.amber : AppColors.border,
                width: primary ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: primary ? 14 : 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: primary ? 22 : 18),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent,
                        fontSize: primary ? 14.5 : 12.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: primary ? 1.4 : 1.1,
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

/// Bilingual copy kept local to this widget, as elsewhere in the Room feature,
/// until the next generated-l10n sweep.
final class _Copy {
  const _Copy({required this.fa});

  factory _Copy.of(BuildContext context) => _Copy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
  );

  final bool fa;

  /// Why the card is empty, said as something to do about it rather than as a
  /// second way of saying nobody is here — the heading above already did that.
  String get aloneBody => fa
      ? 'کدِ اتاق را نشانشان بدهید؛ با یک اسکن وارد می‌شوند.'
      : 'Show someone the room code and one scan puts them in here.';

  String get inviteSomeone => fa ? 'دعوت کنید' : 'INVITE SOMEONE';

  String get addSomeone => fa ? 'افزودن نفر' : 'ADD SOMEONE';

  /// The other reason a channel is empty, said as the thing that is actually
  /// wrong. The room is not short of people; these phones are not on one
  /// network, and no check before this point could have known that.
  String get strandedBody => fa
      ? 'بقیه در این اتاق هستند ولی صدایشان نمی‌رسد — یعنی گوشی‌ها روی یک شبکه نیستند.'
      : 'The others are in this room but nothing is reaching them — which means these phones are not on the same network.';

  String get getOnOneNetwork =>
      fa ? 'وصل شدن به یک شبکه' : 'GET ON ONE NETWORK';
}
