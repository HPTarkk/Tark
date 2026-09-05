import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_accepted_join_snapshot.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../room_member_display_name.dart';

/// Who is in this Room, and how to add someone.
///
/// Replaces a dialog that minted a durable member every time it was *opened* —
/// which is how a two-phone room came to show four people, three of them
/// called "New rider". Nothing here writes to the roster until the host
/// explicitly asks for an invite, and an invite that was never used shows up
/// as exactly what it is: an empty seat, with a way to take it back.
///
/// [autoIssue] mints the invite as the sheet opens instead of waiting for the
/// tap on "Create invite". It is for callers whose own control already *was*
/// that ask — the lobby's "Invite someone", pressed by a host sitting alone in
/// a room they just made. The rule the roster protects is that no seat exists
/// without an explicit request from the user; which screen that request was
/// made on does not change it, and making the host say it twice is what put
/// the QR two taps further away than it needed to be.
Future<void> showRoomPeopleSheet(
  BuildContext context, {
  RoomRepository? repository,
  RoomTransportIdentityLifecycle? identityLifecycle,
  HotspotLinkKeeper? hotspotLinkKeeper,
  TransferRepository? transferRepository,
  bool autoIssue = false,
}) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  // The sheet is tall and the content behind it is the live channel; a scrim
  // that dark makes the hand-off unambiguous without hiding the room.
  barrierColor: Colors.black.withValues(alpha: 0.62),
  builder: (_) => RoomPeopleSheet(
    repository: repository,
    identityLifecycle: identityLifecycle,
    hotspotLinkKeeper: hotspotLinkKeeper,
    transferRepository: transferRepository,
    autoIssue: autoIssue,
  ),
);

class RoomPeopleSheet extends StatefulWidget {
  const RoomPeopleSheet({
    super.key,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.autoIssue = false,
  });

  /// Optional seams for deterministic widget tests. Production resolves the
  /// canonical registrations owned by the Room and transfer features.
  final RoomRepository? repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;

  /// Issue on open, because the caller's own control already asked. See
  /// [showRoomPeopleSheet].
  final bool autoIssue;

  @override
  State<RoomPeopleSheet> createState() => _RoomPeopleSheetState();
}

class _RoomPeopleSheetState extends State<RoomPeopleSheet> {
  RoomRepository get _repository =>
      widget.repository ?? GetIt.instance<RoomRepository>();

  HotspotLinkKeeper? get _hotspotLinkKeeper =>
      widget.hotspotLinkKeeper ??
      (GetIt.instance.isRegistered<HotspotLinkKeeper>()
          ? GetIt.instance<HotspotLinkKeeper>()
          : null);

  TransferRepository? get _transferRepository =>
      widget.transferRepository ??
      (GetIt.instance.isRegistered<TransferRepository>()
          ? GetIt.instance<TransferRepository>()
          : null);

  SavedRoom? _room;
  bool _loading = true;
  bool _issuing = false;
  String? _error;

  /// The invite currently on screen. Held only for the life of this sheet:
  /// re-opening later shows the roster again rather than silently re-issuing.
  _IssuedInvite? _invite;

  /// Whether the next invite lets its holder invite other people.
  bool _grantInvites = false;

  StreamSubscription<HotspotLinkState>? _stateSub;
  StreamSubscription<HotspotCredentials>? _credentialSub;
  HotspotLinkState _linkState = HotspotLinkState.idle;
  HotspotCredentials? _credentials;

  bool get _isTransportHost =>
      _transferRepository?.sessionRole == SessionRole.host;

  bool get _showWifiQr =>
      _isTransportHost &&
      _linkState == HotspotLinkState.up &&
      _credentials != null;

  bool get _showRecovery =>
      _isTransportHost && _linkState == HotspotLinkState.recovering;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    final keeper = _hotspotLinkKeeper;
    if (keeper == null) return;
    _linkState = keeper.state;
    _credentials = keeper.credentials;
    _stateSub = keeper.states.listen((state) {
      if (!mounted) return;
      setState(() {
        _linkState = state;
        if (state == HotspotLinkState.up) _credentials = keeper.credentials;
      });
    });
    _credentialSub = keeper.credentialChanges.listen((credentials) {
      if (!mounted) return;
      setState(() => _credentials = credentials);
    });
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    unawaited(_credentialSub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final selectedId = await _repository.selectedRoomId();
      final saved = selectedId == null
          ? null
          : await _repository.get(selectedId);
      if (!mounted) return;
      setState(() {
        _room = saved;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
    // After the roster is known, never before: issuing needs a Room to issue
    // against, and `_issueInvite` refuses without one. A caller that asked for
    // this gets the QR; one that could not invite falls through to the roster
    // and its explanation, which is the honest answer to "why not".
    if (widget.autoIssue && mounted && _invite == null) {
      await _issueInvite();
    }
  }

  bool _canInvite(SavedRoom? saved) =>
      saved != null &&
      !saved.room.archived &&
      saved.membership.active &&
      saved.membership.canManageInvites;

  /// Mints one invite and the seat that goes with it.
  ///
  /// This is the *only* path that writes a member, and it runs on an explicit
  /// tap. The seat is created pending, so it never inflates the head count
  /// while it is still just a code on a screen, and held only for as long as
  /// the code it shadows can be redeemed.
  Future<void> _issueInvite() async {
    final saved = _room;
    if (_issuing || !_canInvite(saved)) return;
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    setState(() {
      _issuing = true;
      _error = null;
    });
    try {
      final invite = await _repository.issueInvite(
        saved!.room.id,
        kind: RoomInvitationKind.trustedMembership,
        now: DateTime.now().toUtc(),
        ttl: const Duration(hours: 12),
      );
      // Pre-authorise the seat while the issuer and its signing key are here.
      // The resulting QR is a complete one-scan handoff; the joining phone
      // never has to display a reply code back to this one.
      final verified = await _repository.verifyAndRedeemInvite(
        invite,
        now: DateTime.now().toUtc(),
      );
      if (verified == null) throw StateError('Room invite verification failed');
      final accepted = await _repository.acceptVerifiedInvite(
        verified,
        displayName: heldSeatNameFor(fa: fa),
        acceptedAt: DateTime.now().toUtc(),
        pending: true,
        // The seat is the code's shadow, so it dies when the code does. Past
        // this the invite cannot be redeemed by anyone, which makes an
        // unclaimed seat a row that can never be filled — and a host who taps
        // twice, or shows a code and dismisses it, used to keep one forever.
        heldUntil: invite.expiresAt,
      );
      final memberId = RoomMemberId(invite.invitationId.substring(0, 24));
      final identity =
          widget.identityLifecycle ??
          RoomTransportIdentityLifecycle(
            store: PlatformRoomTransportIdentitySecureStore(),
          );
      final memberKeyPair = await identity.createPendingMemberKeyPair();
      final certificate = await identity.issueMemberCertificate(
        issuerRoom: accepted,
        memberId: memberId,
        memberPublicKey: memberKeyPair.publicKey,
      );
      final bundle = RoomDirectJoinBundle(
        memberId: memberId,
        snapshot: RoomAcceptedJoinSnapshot.fromSavedRoom(
          accepted,
          acceptedMemberId: memberId,
          grantsInviteManagement: _grantInvites,
        ),
        memberKeyPair: memberKeyPair,
        certificate: certificate,
        expiresAt: invite.expiresAt,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _room = accepted;
        _issuing = false;
        _invite = _IssuedInvite(
          memberId: memberId,
          encoded: bundle.encode(),
          displayCode: invite.displayCode,
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _issuing = false;
        _error = context.getString.people_issue_error;
      });
    }
  }

  /// Takes an unused seat back.
  Future<void> _revoke(RoomMember member) async {
    final saved = _room;
    if (saved == null) return;
    final next = await _repository.removeMember(saved.room.id, member.id);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _room = next;
      if (_invite?.memberId == member.id) _invite = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: AnimatedSize(
        duration: AppMotion.sheet,
        curve: AppMotion.easeOut,
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: AppMotion.card,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Padding(
        key: ValueKey('people-loading'),
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final saved = _room;
    if (saved == null) {
      return _Message(
        key: const ValueKey('people-none'),
        icon: Icons.meeting_room_outlined,
        text: context.getString.people_no_room,
      );
    }
    final invite = _invite;
    if (invite != null) {
      return _InvitePanel(
        key: const ValueKey('people-invite'),
        room: saved,
        invite: invite,
        grantsInvites: _grantInvites,
        wifi: _showWifiQr ? _credentials : null,
        recovering: _showRecovery,
        onDone: () => setState(() => _invite = null),
      );
    }
    return _Roster(
      key: const ValueKey('people-roster'),
      room: saved,
      canInvite: _canInvite(saved),
      issuing: _issuing,
      error: _error,
      grantInvites: _grantInvites,
      onToggleGrant: (value) => setState(() => _grantInvites = value),
      onInvite: _issueInvite,
      onRevoke: _revoke,
    );
  }
}

/// One live invite, kept only while the sheet is open.
class _IssuedInvite {
  const _IssuedInvite({
    required this.memberId,
    required this.encoded,
    required this.displayCode,
  });

  final RoomMemberId memberId;
  final String encoded;
  final String displayCode;
}

// ── Shell ────────────────────────────────────────────────────────────────────

// ── Roster ───────────────────────────────────────────────────────────────────

class _Roster extends StatelessWidget {
  const _Roster({
    required this.room,
    required this.canInvite,
    required this.issuing,
    required this.error,
    required this.grantInvites,
    required this.onToggleGrant,
    required this.onInvite,
    required this.onRevoke,
    super.key,
  });

  final SavedRoom room;
  final bool canInvite;
  final bool issuing;
  final String? error;
  final bool grantInvites;
  final ValueChanged<bool> onToggleGrant;
  final VoidCallback onInvite;
  final ValueChanged<RoomMember> onRevoke;

  @override
  Widget build(BuildContext context) {
    final confirmed = room.room.confirmedMembers;
    final pending = room.room.pendingMembers;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: StaggeredEntrance(
        builder: (context, children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
        children: [
          SheetTitle(
            title: context.getString.people_title,
            subtitle: room.room.name,
          ),
          const SizedBox(height: 18),
          _SectionLabel(
            text: context.getString.people_in_room(
              confirmed.length.localized(context),
            ),
            icon: Icons.groups_2_rounded,
          ),
          const SizedBox(height: 8),
          for (final member in confirmed)
            _MemberRow(
              member: member,
              isYou: member.id == room.membership.localMemberId,
              onRevoke: null,
            ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 18),
            _SectionLabel(
              text: context.getString.people_held_seats(
                pending.length.localized(context),
              ),
              icon: Icons.hourglass_top_rounded,
              muted: true,
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                context.getString.people_held_seats_hint,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ),
            for (final member in pending)
              _MemberRow(
                member: member,
                isYou: false,
                onRevoke: () => onRevoke(member),
              ),
          ],
          const SizedBox(height: 20),
          if (canInvite) ...[
            _GrantToggle(value: grantInvites, onChanged: onToggleGrant),
            const SizedBox(height: 12),
            _PrimaryAction(
              key: const Key('room-people-invite'),
              icon: Icons.qr_code_2_rounded,
              label: context.getString.people_create_invite,
              busy: issuing,
              onTap: onInvite,
            ),
          ] else
            _Note(text: context.getString.people_cannot_invite),
          if (error != null) ...[
            const SizedBox(height: 12),
            _Note(text: error!, danger: true),
          ],
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isYou,
    required this.onRevoke,
  });

  final RoomMember member;
  final bool isYou;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    // Not the stored string. A confirmed seat can still be carrying the
    // placeholder the host wrote into it, and "Open seat" on an occupied row
    // is the same misrepresentation R7 renamed it to prevent.
    final name = roomMemberDisplayName(
      member,
      // The locale itself, not a translated string. A held seat's placeholder
      // is written into storage in whichever language the host was using, and
      // [roomMemberDisplayName] checks both — so it cannot come from the ARB,
      // which only ever knows what the *reader* is using.
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: context.getString.people_unnamed,
    );
    final pending = member.pending;
    final accent = pending ? AppColors.textSecondary : AppColors.amber;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: pending
              ? AppColors.border
              : AppColors.amber.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.14),
              border: Border.all(color: accent.withValues(alpha: 0.45)),
            ),
            child: Icon(
              pending ? Icons.person_add_alt_rounded : Icons.person_rounded,
              size: 17,
              color: accent,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: pending
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (isYou || pending) ...[
                  const SizedBox(height: 2),
                  Text(
                    isYou
                        ? context.getString.people_you
                        : context.getString.people_waiting,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRevoke != null)
            IconButton(
              tooltip: context.getString.people_revoke,
              onPressed: onRevoke,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _GrantToggle extends StatelessWidget {
  const _GrantToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    toggled: value,
    child: PressableScale(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: value
              ? AppColors.amber.withValues(alpha: 0.10)
              : AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: value
                ? AppColors.amber.withValues(alpha: 0.55)
                : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              value ? Icons.shield_moon_rounded : Icons.shield_outlined,
              size: 19,
              color: value ? AppColors.amber : AppColors.textSecondary,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.getString.people_grant_title,
                    style: TextStyle(
                      color: value ? AppColors.amber : AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.getString.people_grant_hint,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.amber,
            ),
          ],
        ),
      ),
    ),
  );
}

// ── Invite panel ─────────────────────────────────────────────────────────────

class _InvitePanel extends StatelessWidget {
  const _InvitePanel({
    required this.room,
    required this.invite,
    required this.grantsInvites,
    required this.wifi,
    required this.recovering,
    required this.onDone,
    super.key,
  });

  final SavedRoom room;
  final _IssuedInvite invite;
  final bool grantsInvites;
  final HotspotCredentials? wifi;
  final bool recovering;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final credentials = wifi;
    var showNetworkDetails = false;
    return StatefulBuilder(
      builder: (context, setLocalState) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
        child: StaggeredEntrance(
          builder: (context, children) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
          children: [
            SheetTitle(
              title: context.getString.people_invite_title,
              subtitle: room.room.name,
            ),
            const SizedBox(height: 16),
            Center(
              child: GlowingQrCard(
                key: const Key('room-invite-qr'),
                data: invite.encoded,
                size: 250,
                branded:
                    invite.encoded.length <=
                    RoomDirectJoinBundle.brandableEncodedLength,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              context.getString.people_invite_hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            _CheckCode(code: invite.displayCode),
            if (grantsInvites) ...[
              const SizedBox(height: 12),
              _Note(text: context.getString.people_granted_note, accent: true),
            ],
            if (credentials != null || recovering) ...[
              const SizedBox(height: 16),
              _SecondaryAction(
                key: const Key('room-invite-network-help'),
                icon: Icons.wifi_tethering_rounded,
                label: showNetworkDetails
                    ? context.getString.hotspot_hide_credentials
                    : context.getString.hotspot_show_credentials,
                onTap: () => setLocalState(
                  () => showNetworkDetails = !showNetworkDetails,
                ),
              ),
              if (showNetworkDetails) ...[
                const SizedBox(height: 12),
                if (credentials != null)
                  _WifiSection(credentials: credentials)
                else
                  _Note(text: context.getString.people_wifi_recovering),
              ],
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TapConfirmation(
                    builder: (context, copied, confirm) => _SecondaryAction(
                      key: const Key('room-invite-copy'),
                      confirmed: copied,
                      icon: copied ? Icons.check_rounded : Icons.copy_rounded,
                      label: copied
                          ? context.getString.people_copied
                          : context.getString.people_copy_invite,
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: invite.encoded),
                        );
                        confirm();
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PrimaryAction(
                    icon: Icons.check_rounded,
                    label: context.getString.people_done,
                    onTap: onDone,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckCode extends StatelessWidget {
  const _CheckCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      children: [
        Text(
          context.getString.people_code_label,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectableText(
            code,
            key: const Key('room-invite-display-code'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.amber,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          context.getString.people_code_warning,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ],
    ),
  );
}

class _WifiSection extends StatelessWidget {
  const _WifiSection({required this.credentials});

  final HotspotCredentials credentials;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('room-invite-wifi-section'),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.card,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Text(
          context.getString.people_wifi_title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        GlowingQrCard(
          key: const Key('room-invite-wifi-qr'),
          data: credentials.wifiQrPayload,
          size: 180,
          branded: true,
        ),
        const SizedBox(height: 6),
        Text(
          '${context.getString.people_ssid_label}: ${credentials.ssid}',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 12.5),
        ),
        SelectableText(
          '${context.getString.people_password_label}: ${credentials.passphrase}',
          key: const Key('room-invite-wifi-password'),
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 12.5),
        ),
        const SizedBox(height: 6),
        Text(
          context.getString.people_wifi_ephemeral,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ],
    ),
  );
}

// ── Shared bits ──────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.text,
    required this.icon,
    this.muted = false,
  });

  final String text;
  final IconData icon;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppColors.textSecondary : AppColors.amber;
    return Semantics(
      header: true,
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  static final _radius = BorderRadius.circular(14);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: PressableScale(
      onTap: busy ? null : onTap,
      borderRadius: _radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: busy ? 0.06 : 0.12),
          borderRadius: _radius,
          border: Border.all(
            color: AppColors.amber.withValues(alpha: busy ? 0.4 : 1),
            width: 2,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber),
                  ),
                )
              else
                Icon(icon, color: AppColors.amber, size: 19),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.confirmed = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool confirmed;

  static final _radius = BorderRadius.circular(14);

  @override
  Widget build(BuildContext context) {
    final accent = confirmed ? AppColors.green : AppColors.textSecondary;
    return Semantics(
      button: true,
      label: label,
      liveRegion: confirmed,
      child: PressableScale(
        onTap: onTap,
        borderRadius: _radius,
        child: AnimatedContainer(
          duration: AppMotion.chip,
          curve: AppMotion.easeOut,
          decoration: BoxDecoration(
            color: confirmed
                ? AppColors.green.withValues(alpha: 0.10)
                : AppColors.card,
            borderRadius: _radius,
            border: Border.all(
              color: confirmed ? AppColors.green : AppColors.border,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: AnimatedSwitcher(
              duration: AppMotion.chip,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.7, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: Row(
                key: ValueKey(confirmed),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: 18),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: confirmed
                            ? AppColors.green
                            : AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
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

class _Note extends StatelessWidget {
  const _Note({required this.text, this.danger = false, this.accent = false});

  final String text;
  final bool danger;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? AppColors.red
        : accent
        ? AppColors.amber
        : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            danger ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 30, 24, 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 42, color: AppColors.amber),
        const SizedBox(height: 14),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

// ── Copy ─────────────────────────────────────────────────────────────────────
