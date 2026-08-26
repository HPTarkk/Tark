import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';

/// Always-reachable Add Rider entry point for a live Room.
///
/// The durable Room invite and temporary hotspot bootstrap stay deliberately
/// separate. A Room invite remains usable throughout transport recovery; only
/// the current transport host may reveal the current Wi-Fi credentials.
class InRoomInviteButton extends StatefulWidget {
  const InRoomInviteButton({
    super.key,
    this.repository,
    this.hotspotLinkKeeper,
    this.transferRepository,
  });

  /// Optional seams for deterministic widget tests. Production resolves the
  /// canonical registrations owned by the Room and transfer features.
  final RoomRepository? repository;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;

  @override
  State<InRoomInviteButton> createState() => _InRoomInviteButtonState();
}

class _InRoomInviteButtonState extends State<InRoomInviteButton> {
  bool _busy = false;

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

  @override
  Widget build(BuildContext context) {
    final copy = _InviteCopy.of(context);
    return IconButton(
      key: const Key('in-room-add-rider'),
      tooltip: copy.addRider,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      onPressed: _busy ? null : _openInvite,
      icon: _busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.person_add_alt_1_rounded, color: AppColors.amber),
    );
  }

  Future<void> _openInvite() async {
    if (_busy) return;
    setState(() => _busy = true);
    final copy = _InviteCopy.of(context);
    try {
      final selectedId = await _repository.selectedRoomId();
      final saved = selectedId == null
          ? null
          : await _repository.get(selectedId);
      if (!mounted) return;
      if (!_canInvite(saved)) {
        _showMessage(copy.unavailable);
        return;
      }

      final invite = await _repository.issueInvite(
        saved!.room.id,
        kind: RoomInvitationKind.trustedMembership,
        now: DateTime.now().toUtc(),
        ttl: const Duration(hours: 12),
      );
      if (!mounted) return;

      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _RoomInviteDialog(
          room: saved,
          invite: invite,
          copy: copy,
          hotspotLinkKeeper: _hotspotLinkKeeper,
          transferRepository: _transferRepository,
        ),
      );
    } catch (_) {
      if (mounted) _showMessage(copy.error);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  bool _canInvite(SavedRoom? saved) =>
      saved != null &&
      !saved.room.archived &&
      saved.membership.active &&
      saved.membership.canManageInvites;

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

class _RoomInviteDialog extends StatefulWidget {
  const _RoomInviteDialog({
    required this.room,
    required this.invite,
    required this.copy,
    required this.hotspotLinkKeeper,
    required this.transferRepository,
  });

  final SavedRoom room;
  final RoomInvitation invite;
  final _InviteCopy copy;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;

  @override
  State<_RoomInviteDialog> createState() => _RoomInviteDialogState();
}

class _RoomInviteDialogState extends State<_RoomInviteDialog> {
  StreamSubscription<HotspotLinkState>? _stateSub;
  StreamSubscription<HotspotCredentials>? _credentialSub;
  HotspotLinkState _linkState = HotspotLinkState.idle;
  HotspotCredentials? _credentials;

  bool get _isTransportHost =>
      widget.transferRepository?.sessionRole == SessionRole.host;

  bool get _showWifiQr =>
      _isTransportHost &&
      _linkState == HotspotLinkState.up &&
      _credentials != null;

  bool get _showRecovery =>
      _isTransportHost && _linkState == HotspotLinkState.recovering;

  @override
  void initState() {
    super.initState();
    final keeper = widget.hotspotLinkKeeper;
    if (keeper == null) return;
    _linkState = keeper.state;
    _credentials = keeper.credentials;
    _stateSub = keeper.states.listen((state) {
      if (!mounted) return;
      setState(() {
        _linkState = state;
        if (state == HotspotLinkState.up) {
          _credentials = keeper.credentials;
        }
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

  @override
  Widget build(BuildContext context) {
    final encoded = widget.invite.encode();
    final copy = widget.copy;
    return Dialog(
      key: const Key('room-invite-dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                copy.title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.room.room.name,
                        key: const Key('room-invite-room-name'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 12),
                      _InviteQr(
                        key: const Key('room-invite-qr'),
                        data: encoded,
                        semanticsLabel: copy.qrSemantics,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        copy.codeLabel,
                        style: const TextStyle(fontSize: 12),
                      ),
                      SelectableText(
                        widget.invite.displayCode,
                        key: const Key('room-invite-display-code'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.amber,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        copy.codeWarning,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      if (_showWifiQr) ...[
                        const SizedBox(height: 20),
                        _WifiInviteSection(
                          credentials: _credentials!,
                          copy: copy,
                        ),
                      ] else if (_showRecovery) ...[
                        const SizedBox(height: 20),
                        _WifiRecoverySection(copy: copy),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    key: const Key('room-invite-copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: encoded));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(copy.copied)));
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(copy.copyInvite),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(copy.done),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InviteQr extends StatelessWidget {
  const _InviteQr({
    super.key,
    required this.data,
    required this.semanticsLabel,
  });

  final String data;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 216,
      height: 216,
      padding: const EdgeInsets.all(10),
      color: Colors.white,
      child: QrImageView(
        data: data,
        size: 196,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(color: Colors.black),
        dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
        semanticsLabel: semanticsLabel,
      ),
    );
  }
}

class _WifiInviteSection extends StatelessWidget {
  const _WifiInviteSection({required this.credentials, required this.copy});

  final HotspotCredentials credentials;
  final _InviteCopy copy;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('room-invite-wifi-section'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            copy.wifiTitle,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          _InviteQr(
            key: const Key('room-invite-wifi-qr'),
            data: credentials.wifiQrPayload,
            semanticsLabel: copy.wifiQrSemantics,
          ),
          const SizedBox(height: 8),
          Text('${copy.ssidLabel}: ${credentials.ssid}'),
          SelectableText(
            '${copy.passwordLabel}: ${credentials.passphrase}',
            key: const Key('room-invite-wifi-password'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            copy.wifiEphemeral,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _WifiRecoverySection extends StatelessWidget {
  const _WifiRecoverySection({required this.copy});

  final _InviteCopy copy;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('room-invite-wifi-recovering'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.amber.withAlpha(100)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(copy.wifiRecovering)),
        ],
      ),
    );
  }
}

final class _InviteCopy {
  const _InviteCopy({required this.fa});

  factory _InviteCopy.of(BuildContext context) => _InviteCopy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
  );

  final bool fa;

  String get addRider => fa ? 'افزودن همراه' : 'Add rider';
  String get title => fa ? 'دعوت به اتاق' : 'Room invite';
  String get codeLabel => fa ? 'کد بررسی اتاق' : 'Room check code';
  String get codeWarning => fa
      ? 'این کد فقط برای بررسی است و به‌تنهایی اجازه ورود نمی‌دهد.'
      : 'This code is only a check value and cannot authorize joining by itself.';
  String get copyInvite => fa ? 'کپی دعوت' : 'Copy invite';
  String get copied => fa ? 'دعوت کپی شد' : 'Invite copied';
  String get done => fa ? 'تمام' : 'Done';
  String get unavailable => fa
      ? 'برای دعوت، ابتدا یک اتاق فعال با مجوز دعوت انتخاب کنید.'
      : 'Select an active Room where you can manage invites first.';
  String get error => fa
      ? 'ساخت دعوت ممکن نشد. دوباره تلاش کنید.'
      : 'Could not create the invite. Try again.';
  String get qrSemantics =>
      fa ? 'کیوآر دعوت امن اتاق' : 'Secure Room invite QR';
  String get wifiTitle => fa ? 'اتصال وای‌فای میزبان' : 'Host Wi-Fi connection';
  String get ssidLabel => fa ? 'نام شبکه' : 'Network';
  String get passwordLabel => fa ? 'رمز عبور' : 'Password';
  String get wifiEphemeral => fa
      ? 'این اطلاعات فقط مربوط به اتصال فعلی است و شناسه اتاق نیست.'
      : 'These credentials belong only to the current connection, not the Room.';
  String get wifiRecovering => fa
      ? 'هات‌اسپات در حال بازیابی است. کیوآر قدیمی غیرفعال شده و بعد از آماده‌شدن شبکه جدید تازه می‌شود.'
      : 'Hotspot is recovering. The stale Wi-Fi QR is disabled and will refresh when the new network is ready.';
  String get wifiQrSemantics =>
      fa ? 'کیوآر اتصال وای‌فای میزبان' : 'Host Wi-Fi connection QR';
}
