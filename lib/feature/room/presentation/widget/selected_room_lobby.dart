import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room.dart';
import '../../domain/repository/room_repository.dart';
import '../room_member_display_name.dart';
import 'in_room_invite_button.dart';
import 'room_people_sheet.dart';

/// Read-only durable Room lobby shown before a live transport is started.
///
/// Inviting members remains available before transport starts, keeping logical
/// Room membership separate from Wi-Fi/hotspot setup.
///
/// **This screen's job changes with the roster.** A room with one person in it
/// is not a room yet, and the only useful thing to do with it is put someone
/// else in — so that case gets the whole body, in the shape the empty saved-
/// rooms list already uses: name the situation, then offer the single thing
/// that resolves it. Everything the host could do about it used to live in one
/// pill in the app bar, which is a place you find by looking rather than by
/// reading, and only if you already suspected it was there. Once somebody else
/// is in the room, Start ride is the point again and inviting steps back down
/// to a quiet control under the roster.
class SelectedRoomLobby extends StatefulWidget {
  const SelectedRoomLobby({
    required this.room,
    required this.onStartRide,
    required this.onBack,
    this.link,
    this.mode,
    this.onConnect,
    this.repository,
    super.key,
  });

  /// The Room as the composition root resolved it. A seed only — the roster
  /// changes under this screen (an invite mints a held seat; a rider's proof
  /// confirms one) and the lobby re-reads rather than going on showing what
  /// was true when it opened.
  final SavedRoom room;
  final VoidCallback onStartRide;

  /// What is carrying this room right now, or null when nobody has been able
  /// to say yet.
  ///
  /// Null and [LiveLink.none] are deliberately different. Null is the first
  /// frame, and a composition with no probe in it — and on both the screen
  /// keeps its original shape, because a lobby that flashes "not connected"
  /// for one frame on the way to "Start ride" would teach the user to
  /// disbelieve the line. [LiveLink.none] is an answer, and it changes what
  /// the screen is for.
  final LiveLink? link;

  /// The transport in effect, which is the only thing that can say whether
  /// [link] was *arranged* or merely found — see [LiveLink.arranged]. Null
  /// carries the same meaning as a null [link]: nobody has said yet, so the
  /// screen claims nothing.
  final TransferMode? mode;

  /// Opens the way to getting a link. Null where the caller cannot offer one,
  /// which leaves this screen saying what is missing without pretending it
  /// can fix it.
  final VoidCallback? onConnect;

  /// The way back out.
  ///
  /// Creating a room lands here by *replacing* the stack, so this screen is
  /// routinely the only route on it and there is no system back to inherit —
  /// Android's back gesture closed the app instead. The caller decides where
  /// "out" is, because only the composition root knows what is underneath.
  final VoidCallback onBack;

  /// An optional seam for deterministic widget tests. Production resolves the
  /// canonical registration owned by the Room feature.
  final RoomRepository? repository;

  @override
  State<SelectedRoomLobby> createState() => _SelectedRoomLobbyState();
}

class _SelectedRoomLobbyState extends State<SelectedRoomLobby> {
  late SavedRoom _room = widget.room;
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
    _changes = _repository?.changes.listen((_) {
      if (mounted) unawaited(_reload());
    });
  }

  @override
  void didUpdateWidget(SelectedRoomLobby oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.room.id != widget.room.room.id) _room = widget.room;
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final next = await repository.get(_room.room.id);
      // A Room that has gone is not this screen's problem to report: the entry
      // above re-resolves before it starts anything, and blanking the roster
      // here would only replace a stale answer with no answer.
      if (next != null && mounted) setState(() => _room = next);
    } catch (_) {
      // The seed stays on screen. One storage read out of date at worst, and
      // still the Room the user chose.
    }
  }

  Future<void> _invite({required bool straightToCode}) async {
    HapticFeedback.selectionClick();
    await showRoomPeopleSheet(
      context,
      repository: widget.repository,
      autoIssue: straightToCode,
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _LobbyCopy.of(context);
    // Confirmed, not merely active: a seat held open by an unused invite is
    // durable and authorised but nobody is standing in it, and listing it as a
    // member is what made two phones disagree about how many people were in
    // the room. It still gets shown — as exactly what it is, further down.
    final members = _room.room.confirmedMembers;
    final held = _room.room.pendingMembers;
    final canInvite =
        !_room.room.archived &&
        _room.membership.active &&
        _room.membership.canManageInvites;
    // One person and no outstanding code: nothing here has anyone to talk to.
    final alone = members.length <= 1 && held.isEmpty;
    // Nothing is carrying this room. Outranks [alone] as the thing the screen
    // is about, and not only because a channel needs a link before it needs a
    // second person: the invite code is *made of* the link — it hands over the
    // hotspot's credentials — so inviting somebody from a phone with no link
    // gives them a code that cannot put them anywhere.
    final unlinked = widget.link == LiveLink.none;
    // A link is up, and nobody arranged it — which in practice means exactly
    // one thing: this phone is on a Wi-Fi network that was already there when
    // the app opened. That is a fact about this phone and no evidence at all
    // about anybody else, and the scenario it fails on is the ordinary one:
    // you set the ride up at home, on the home Wi-Fi, and then you leave with
    // it. `TransportAdvisor` has always reasoned this way — its hotspot rung
    // leads *because* `hasWifi` cannot see the other phone — and this screen
    // was the last one still reading a network it found as the network the
    // room is on. See [LiveLink.arranged].
    final link = widget.link;
    final mode = widget.mode;
    final assumed =
        link != null && mode != null && link.isUp && !link.arranged(mode);

    return Scaffold(
      appBar: AppBar(
        // Nothing has started here — the screen's own promise is that no
        // hotspot, microphone or transport is running yet — so leaving needs
        // no confirmation. That is the whole difference between this control
        // and the channel's, which wears the same chevron over a question.
        leading: Semantics(
          button: true,
          label: copy.back,
          child: IconButton(
            key: const Key('selected-room-lobby-back'),
            tooltip: copy.back,
            onPressed: () {
              HapticFeedback.selectionClick();
              widget.onBack();
            },
            icon: Icon(
              Icons.arrow_back_rounded,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        title: Text(_room.room.name),
        // Absent while the roster is one row saying "You". It opens a list
        // with nothing in it, and in amber beside an amber callout that says
        // the same thing it becomes the second answer to a question the screen
        // has just answered once.
        actions: alone
            ? const []
            : const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: InRoomInviteButton(),
                ),
              ],
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
              unlinked
                  ? copy.unlinkedHeading
                  : assumed
                  ? copy.assumedHeading
                  : (alone ? copy.aloneHeading : copy.heading),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              unlinked
                  ? copy.unlinkedLead
                  : assumed
                  ? copy.assumedLead
                  : copy.nothingStarted,
            ),
            if (widget.link != null && !unlinked) ...[
              const SizedBox(height: 14),
              _LinkChip(link: widget.link!, copy: copy),
              // The caveat, and the way out of it. Being on a network is not
              // being on *their* network, and this screen has no way to tell
              // the two apart — so it says so rather than letting the chip
              // above be read as "the room is ready".
              // Dropped when [assumed] is about to put the same caveat inside
              // the callout below, at the weight it deserves. One warning in
              // two sizes reads as two different problems.
              if (!widget.link!.provesPeer && !assumed) ...[
                const SizedBox(height: 8),
                Text(
                  copy.linkCaveat(widget.link!),
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
                if (widget.onConnect != null) ...[
                  const SizedBox(height: 8),
                  _WayOut(
                    key: const Key('selected-room-different-network'),
                    label: copy.differentNetwork,
                    onTap: widget.onConnect!,
                  ),
                ],
              ],
            ],
            const SizedBox(height: 20),
            if (unlinked)
              ..._unlinkedBody(copy, members, held, canInvite: canInvite)
            // Outranks [alone], and for the same reason [unlinked] does: an
            // invite minted from here carries membership and no network — the
            // People sheet only grows its Wi-Fi section once an access point
            // of ours is up — so it would put somebody into a room they still
            // cannot hear.
            else if (assumed)
              ..._assumedBody(copy, members, held, canInvite: canInvite)
            else if (alone)
              ..._aloneBody(copy, canInvite: canInvite)
            else ...[
              ..._rosterList(copy, members, held, canInvite: canInvite),
              const SizedBox(height: 20),
              _LobbyAction(
                key: const Key('selected-room-start-ride'),
                icon: Icons.play_arrow_rounded,
                label: copy.startRide,
                primary: true,
                onTap: widget.onStartRide,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The empty saved-rooms state, one level in: say what is true, then offer
  /// the one thing that changes it.
  List<Widget> _aloneBody(_LobbyCopy copy, {required bool canInvite}) => [
    _InviteInvitation(
      key: const Key('selected-room-invite-callout'),
      copy: copy,
      roomName: _room.room.name,
      onInvite: canInvite ? () => _invite(straightToCode: true) : null,
    ),
    const SizedBox(height: 22),
    // Deliberately still available, and deliberately quiet. Starting alone is
    // a real thing to do — it is what brings the hotspot up, and the invite
    // code gains the Wi-Fi credentials once it is — but it is not what someone
    // who has just made a room came here for.
    _LobbyAction(
      key: const Key('selected-room-start-ride'),
      icon: Icons.play_arrow_rounded,
      label: copy.startRide,
      primary: false,
      onTap: widget.onStartRide,
    ),
    const SizedBox(height: 10),
    Text(
      copy.startAloneHint,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppColors.textSecondary,
        fontSize: 11.5,
        height: 1.45,
      ),
    ),
  ];

  /// The screen when the link is real but nobody arranged it.
  ///
  /// **This is the inversion, and it is the whole request.** The shape used to
  /// be: Start ride glowing amber under a chip that said "On Wi-Fi", with the
  /// escape — *Not on the same network?* — as one line of small underlined
  /// text below it. That put the app's weight behind the one claim it cannot
  /// check, and left the reliable route as the thing you notice last. So the
  /// two swap places: making a network the two phones share is the primary
  /// action, and "we are already together" is the quiet line under it.
  ///
  /// The line is still a real way through, not a warning with no door — a
  /// pair genuinely sat on one office network gets on the air in one tap, the
  /// same tap it used to take. What changed is which of the two the screen
  /// argues for, and it now argues for the one that is still true after
  /// everybody stands up and leaves.
  List<Widget> _assumedBody(
    _LobbyCopy copy,
    List<RoomMember> members,
    List<RoomMember> held, {
    required bool canInvite,
  }) => [
    _SharedNetworkDoubt(
      key: const Key('selected-room-shared-network-callout'),
      copy: copy,
      onConnect: widget.onConnect,
    ),
    // With no way out to offer there is nothing to invert *towards*, so the
    // original control comes back at full weight rather than leaving a screen
    // whose only action is a sentence. Same rule as [_unlinkedBody].
    if (widget.onConnect == null) ...[
      const SizedBox(height: 22),
      _LobbyAction(
        key: const Key('selected-room-start-ride'),
        icon: Icons.play_arrow_rounded,
        label: copy.startRide,
        primary: true,
        onTap: widget.onStartRide,
      ),
    ] else ...[
      const SizedBox(height: 12),
      Center(
        child: _WayOut(
          key: const Key('selected-room-start-anyway'),
          icon: Icons.play_arrow_rounded,
          label: copy.alreadyTogether,
          onTap: widget.onStartRide,
        ),
      ),
    ],
    const SizedBox(height: 24),
    ..._rosterList(copy, members, held, canInvite: canInvite),
  ];

  /// The screen when nothing is carrying the room.
  ///
  /// The roster stays — who is in this room is durable and true whatever the
  /// radios are doing, and blanking it would make a temporary problem look
  /// like a lost room. What it loses is Start ride, which is the point: a
  /// gate that leaves the old control on screen to fail quietly is worse than
  /// no gate, so the one action here is the one that resolves the situation.
  /// Inviting stays available and stays quiet below.
  List<Widget> _unlinkedBody(
    _LobbyCopy copy,
    List<RoomMember> members,
    List<RoomMember> held, {
    required bool canInvite,
  }) => [
    _LinkInvitation(
      key: const Key('selected-room-link-callout'),
      copy: copy,
      onConnect: widget.onConnect,
    ),
    // Without a way out to offer, the callout above has said what is wrong and
    // there is nothing here that can fix it — so the original control comes
    // back rather than leaving the screen with no action at all. The entry
    // above still refuses to open a channel over nothing.
    if (widget.onConnect == null) ...[
      const SizedBox(height: 22),
      _LobbyAction(
        key: const Key('selected-room-start-ride'),
        icon: Icons.play_arrow_rounded,
        label: copy.startRide,
        primary: false,
        onTap: widget.onStartRide,
      ),
    ],
    const SizedBox(height: 24),
    ..._rosterList(copy, members, held, canInvite: canInvite),
  ];

  List<Widget> _rosterList(
    _LobbyCopy copy,
    List<RoomMember> members,
    List<RoomMember> held, {
    required bool canInvite,
  }) => [
    Semantics(
      header: true,
      child: Text(
        copy.members(members.length),
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
        // Shared with the People sheet: a seat confirmed from live evidence
        // still carries the "Open seat" placeholder the host wrote into it,
        // and this list is only ever confirmed members.
        title: Text(
          roomMemberDisplayName(member, fa: copy.fa, unnamed: copy.unnamed),
        ),
        subtitle: member.id == _room.membership.localMemberId
            ? Text(copy.you)
            : null,
      ),
    // An invite that has been made but not walked through. Shown because the
    // alternative is a host who has just handed out a code watching a roster
    // that says nothing happened.
    if (held.isNotEmpty) ...[
      const SizedBox(height: 14),
      Semantics(
        header: true,
        child: Text(
          copy.heldSeats(held.length),
          key: const Key('selected-room-held-seats'),
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(height: 2),
      Text(
        copy.heldSeatsHint,
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11.5,
          height: 1.45,
        ),
      ),
      for (final seat in held)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.hourglass_top_rounded,
            color: AppColors.textSecondary,
          ),
          title: Text(
            roomMemberDisplayName(seat, fa: copy.fa, unnamed: copy.unnamed),
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
    ],
    if (canInvite) ...[
      const SizedBox(height: 14),
      _LobbyAction(
        key: const Key('selected-room-invite'),
        icon: Icons.person_add_alt_1_rounded,
        label: copy.inviteMore,
        primary: false,
        onTap: () => _invite(straightToCode: false),
      ),
    ],
  ];
}

/// The one thing a room with nobody in it needs.
///
/// Modelled on the empty saved-rooms list, which is the shape in this app that
/// already works: a mark, the situation in one line, why it matters in one
/// more, and a single control that resolves it. Without the invite right it
/// keeps the first three and drops the fourth rather than offering a button
/// that would refuse.
class _InviteInvitation extends StatelessWidget {
  const _InviteInvitation({
    required this.copy,
    required this.roomName,
    required this.onInvite,
    super.key,
  });

  final _LobbyCopy copy;
  final String roomName;
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.30)),
    ),
    child: Column(
      children: [
        Icon(Icons.group_add_rounded, size: 46, color: AppColors.amber),
        const SizedBox(height: 14),
        Text(
          copy.aloneTitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          onInvite == null ? copy.aloneNoRight : copy.aloneBody(roomName),
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        if (onInvite != null) ...[
          const SizedBox(height: 18),
          _LobbyAction(
            key: const Key('selected-room-invite'),
            icon: Icons.qr_code_2_rounded,
            label: copy.inviteSomeone,
            primary: true,
            onTap: onInvite!,
          ),
        ],
      ],
    ),
  );
}

/// What the room is missing when it is missing the only thing it cannot do
/// without.
///
/// Same shape as [_InviteInvitation] on purpose — mark, situation, why it
/// matters, one control — because they are the same kind of moment: a room
/// that is not yet a room, and the single act that changes that. The glyph is
/// red and the action is amber, which is the whole message in two colours:
/// something is wrong, and here is the thing that fixes it.
class _LinkInvitation extends StatelessWidget {
  const _LinkInvitation({
    required this.copy,
    required this.onConnect,
    super.key,
  });

  final _LobbyCopy copy;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.30)),
    ),
    child: Column(
      children: [
        Icon(Icons.wifi_tethering_off_rounded, size: 46, color: AppColors.red),
        const SizedBox(height: 14),
        Text(
          copy.unlinkedTitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          onConnect == null ? copy.unlinkedNoWayOut : copy.unlinkedBody,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        if (onConnect != null) ...[
          const SizedBox(height: 18),
          _LobbyAction(
            key: const Key('selected-room-connect'),
            icon: Icons.wifi_tethering_rounded,
            label: copy.connect,
            primary: true,
            onTap: onConnect!,
          ),
        ],
      ],
    ),
  );
}

/// The doubt a Wi-Fi network deserves, at the size of the doubt.
///
/// Third in the family [_InviteInvitation] and [_LinkInvitation] belong to —
/// mark, situation, why it matters, one control — and deliberately the same
/// card, because it is the same kind of moment: something stands between this
/// room and a working channel, and there is one act that settles it.
///
/// **Amber throughout, where [_LinkInvitation] is red.** Nothing is broken
/// here. A link exists and might well be the right one; what is missing is any
/// way to know, and a red glyph would overstate that into a fault. The colour
/// is the difference between "this cannot work" and "this might not".
class _SharedNetworkDoubt extends StatelessWidget {
  const _SharedNetworkDoubt({
    required this.copy,
    required this.onConnect,
    super.key,
  });

  final _LobbyCopy copy;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.30)),
    ),
    child: Column(
      children: [
        Icon(Icons.help_outline_rounded, size: 46, color: AppColors.amber),
        const SizedBox(height: 14),
        Text(
          copy.assumedTitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          onConnect == null ? copy.assumedNoWayOut : copy.assumedBody,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        if (onConnect != null) ...[
          const SizedBox(height: 18),
          _LobbyAction(
            key: const Key('selected-room-connect'),
            icon: Icons.wifi_tethering_rounded,
            label: copy.getOnOneNetwork,
            primary: true,
            onTap: onConnect!,
          ),
        ],
      ],
    ),
  );
}

/// One quiet line saying what this phone is on.
///
/// Deliberately still, with no pulsing dot and no meter. This screen's whole
/// promise is that nothing has started yet, and anything that looks like live
/// traffic would contradict it one line under the sentence that says so.
///
/// **It said READY once, and that was a lie.** A link is a fact about this
/// phone; "ready" is a claim about the room, and the two are only the same
/// thing when the link is itself proof of a peer — which is Bluetooth and
/// nothing else (see [LiveLink.provesPeer]). So the confirming green and the
/// word only appear there, and the rest get amber: something is up, and who
/// is on the far end of it is not known yet.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.link, required this.copy});

  final LiveLink link;
  final _LobbyCopy copy;

  @override
  Widget build(BuildContext context) {
    final proven = link.provesPeer;
    final accent = proven ? AppColors.green : AppColors.amber;
    final label = copy.linkName(link);
    return Semantics(
      label: proven ? '$label — ${copy.linkConnected}' : label,
      excludeSemantics: true,
      child: Container(
        key: const Key('selected-room-link-chip'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Icon(_glyph, size: 17, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // Only where it is true. A badge on every row would be read as a
            // verdict on the room, which is the thing this chip cannot give.
            if (proven)
              Text(
                copy.linkConnected,
                style: TextStyle(
                  color: accent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData get _glyph => switch (link) {
    LiveLink.wifi => Icons.wifi_rounded,
    LiveLink.hotspotHost => Icons.wifi_tethering_rounded,
    LiveLink.bluetooth => Icons.bluetooth_connected_rounded,
    LiveLink.none => Icons.wifi_tethering_off_rounded,
  };
}

/// A quiet text control for "that assumption is wrong for me".
///
/// The same shape Landing uses under its channel actions, and for the same
/// reason: an escape from a default the screen cannot verify has to be
/// visible without competing with the action it is an escape from.
class _WayOut extends StatelessWidget {
  const _WayOut({
    required this.label,
    required this.onTap,
    this.icon = Icons.wifi_tethering_rounded,
    super.key,
  });

  final String label;
  final VoidCallback onTap;

  /// Defaulted to the bridge's glyph, because that is what this control was
  /// built to escape *to*. The inverted lobby passes the play arrow instead:
  /// there the escape runs the other way, and a tethering mark on a control
  /// that starts the ride would say the opposite of what it does.
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: AppColors.amber),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.amber.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The lobby's two weights of action.
///
/// Deliberately not a `FilledButton`/`OutlinedButton` pair: a single gesture
/// owner, so the press settle, the haptic and the callback cannot disagree
/// about who handled the tap — and the amber treatment ties the primary to the
/// primary action on Landing, which is the same promise one step earlier.
///
/// Exactly one of these glows on any given lobby, which is the whole point of
/// the variant: the screen has to be able to say which of "invite" and "start"
/// is the thing to press, and that answer depends on the roster.
class _LobbyAction extends StatelessWidget {
  const _LobbyAction({
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
              padding: EdgeInsets.symmetric(vertical: primary ? 15 : 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: primary ? 24 : 19),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent,
                        fontSize: primary ? 15 : 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: primary ? 1.5 : 1.1,
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

/// Bilingual copy kept local to this screen, as elsewhere in the Room feature,
/// until the next generated-l10n sweep.
final class _LobbyCopy {
  const _LobbyCopy({required this.fa, required this.context});

  factory _LobbyCopy.of(BuildContext context) => _LobbyCopy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
    context: context,
  );

  final bool fa;
  final BuildContext context;

  String get back => fa ? 'بازگشت' : 'Back';
  String get heading => fa ? 'آماده شروع ارتباط' : 'Ready to start';
  String get aloneHeading => fa ? 'اتاق ساخته شد' : 'Your room is ready';
  String get nothingStarted => fa
      ? 'تا وقتی «شروع ارتباط» را نزنید، هیچ هات‌اسپات، میکروفن یا اتصال زنده‌ای شروع نمی‌شود.'
      : 'No hotspot, microphone, or live transport starts until you press Start ride.';
  String get aloneTitle => fa ? 'هنوز تنها هستید' : "You're the only one here";
  String aloneBody(String room) => fa
      ? 'هنوز کسی جز شما در «$room» نیست. کد دعوت را نشانشان بدهید — با یک اسکن وارد همین اتاق می‌شوند، بدون اینترنت.'
      : 'Nobody else is in “$room” yet. Show them the invite code — one scan puts them in this room, with no internet.';
  String get aloneNoRight => fa
      ? 'هنوز کسی جز شما اینجا نیست. دعوت کردن دست میزبان این اتاق است.'
      : 'Nobody else is here yet. Adding people is up to whoever runs this room.';
  String get inviteSomeone => fa ? 'دعوت کردن' : 'INVITE SOMEONE';
  String get inviteMore => fa ? 'دعوت کسی دیگر' : 'INVITE SOMEONE ELSE';
  String get startRide => fa ? 'شروع ارتباط' : 'Start ride';
  String get unlinkedHeading => fa ? 'هنوز وصل نیستید' : 'Not connected yet';
  String get unlinkedLead => fa
      ? 'برای شروع ارتباط، این گوشی باید روی یک شبکه باشد.'
      : 'This phone has to be on something before the channel can open.';
  String get unlinkedTitle => fa ? 'هیچ اتصالی برقرار نیست' : 'No link yet';
  String get unlinkedBody => fa
      ? 'تارک روی وای‌فای، هات‌اسپاتی که یکی‌تان روشن می‌کند، یا بلوتوث کار می‌کند — بدون اینترنت و بدون سیم‌کارت. الان این گوشی روی هیچ‌کدام نیست.'
      : 'Tark runs over Wi-Fi, a hotspot one of you turns on, or Bluetooth — no internet, no SIM. Right now this phone is on none of them.';
  String get unlinkedNoWayOut => fa
      ? 'الان این گوشی روی هیچ شبکه‌ای نیست. وای‌فای را روشن کنید یا از صفحهٔ اتصال، هات‌اسپات را بالا بیاورید.'
      : 'This phone is not on any network right now. Turn Wi-Fi on, or bring a hotspot up from the connect screen.';
  String get connect => fa ? 'برقراری اتصال' : 'GET CONNECTED';
  String get assumedHeading => fa ? 'یک قدم مانده' : 'One thing first';
  String get assumedLead => fa
      ? 'روی وای‌فای بودن، با روی وای‌فایِ آن‌ها بودن یکی نیست.'
      : 'Being on Wi-Fi is not the same as being on their Wi-Fi.';
  String get assumedTitle =>
      fa ? 'همه روی همین شبکه‌اند؟' : 'Are they on this network?';
  String get assumedBody => fa
      ? 'این گوشی روی شبکه‌ای است که از قبل بوده — و از اینجا هیچ راهی نیست که بفهمیم بقیه هم روی همان هستند. شبکه‌ای هم که چند دقیقهٔ دیگر از آن دور می‌شوید، جای شروع ارتباط نیست. هات‌اسپاتی که یکی‌تان روشن می‌کند هرجا بروید کار می‌کند: شما کد را نشان می‌دهید، آن‌ها اسکن می‌کنند.'
      : 'This phone is on a network that was already here, and there is no way from this side to tell whether the others are on it too — nor whether it will still be under you in ten minutes. A hotspot one of you turns on works wherever you end up: you show a code, they scan it.';
  String get assumedNoWayOut => fa
      ? 'این گوشی روی شبکه‌ای است که از قبل بوده. تا صدایی نرسد، معلوم نیست بقیه هم روی همان باشند.'
      : 'This phone is on a network that was already here. Until someone is heard, there is no telling whether the others are on it.';
  String get getOnOneNetwork =>
      fa ? 'یک شبکهٔ مشترک بسازید' : 'GET ON ONE NETWORK';
  String get alreadyTogether => fa
      ? 'همین حالا روی یک شبکه‌ایم — شروع کن'
      : "We're already on the same network — start";
  String get linkConnected => fa ? 'وصل' : 'CONNECTED';
  String get differentNetwork =>
      fa ? 'روی یک شبکه نیستید؟' : 'Not on the same network?';

  /// What the link does *not* tell you. One line per link, because the gap is
  /// a different gap each time: a network says nothing about who else is on
  /// it, while an access point of your own says exactly one thing — nobody
  /// has joined it yet.
  String linkCaveat(LiveLink link) => switch (link) {
    LiveLink.wifi =>
      fa
          ? 'بقیه هم باید روی همین شبکه باشند. تا وقتی صدایی نرسد، از اینجا نمی‌شود فهمید هستند یا نه.'
          : 'The others have to be on this same network. Until someone is heard, there is no way to tell from here whether they are.',
    LiveLink.hotspotHost =>
      fa
          ? 'هات‌اسپات شما روشن است، ولی تا کدتان را اسکن نکنند کسی روی آن نیست.'
          : 'Your hotspot is up, but nobody is on it until they scan your code.',
    LiveLink.bluetooth || LiveLink.none => '',
  };
  String linkName(LiveLink link) => switch (link) {
    LiveLink.wifi => fa ? 'روی وای‌فای' : 'On Wi-Fi',
    LiveLink.hotspotHost =>
      fa ? 'هات‌اسپات شما روشن است' : 'Your hotspot is up',
    LiveLink.bluetooth => fa ? 'اتصال بلوتوث' : 'Bluetooth link',
    LiveLink.none => fa ? 'بدون اتصال' : 'No link',
  };
  String get startAloneHint => fa
      ? 'یا همین حالا شروع کنید و بعد از روشن‌شدن ارتباط دعوت کنید.'
      : 'Or start now and invite once you are on the air.';
  String get you => fa ? 'شما' : 'You';
  String get unnamed => fa ? 'عضو اتاق' : 'Room member';
  String get heldSeatsHint => fa
      ? 'کدشان را گرفته‌اند ولی هنوز اسکن نکرده‌اند.'
      : 'They have a code but have not scanned it yet.';

  String members(int count) => fa
      ? 'اعضای اتاق (${count.localized(context)})'
      : 'Room members (${count.localized(context)})';
  String heldSeats(int count) => fa
      ? 'در انتظار پیوستن (${count.localized(context)})'
      : 'Waiting to join (${count.localized(context)})';
}
