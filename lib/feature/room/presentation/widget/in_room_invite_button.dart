import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';

/// Always-reachable Add Rider entry point for a live Room.
///
/// This intentionally issues only a durable Room invitation. Wi-Fi/hotspot
/// bootstrap credentials are a separate, ephemeral transport concern and are
/// never inferred from ChannelId, IP address or the current transport role.
class InRoomInviteButton extends StatefulWidget {
  const InRoomInviteButton({super.key, this.repository});

  /// Optional seam for deterministic widget tests. Production resolves the
  /// canonical repository registered by the Room feature.
  final RoomRepository? repository;

  @override
  State<InRoomInviteButton> createState() => _InRoomInviteButtonState();
}

class _InRoomInviteButtonState extends State<InRoomInviteButton> {
  bool _busy = false;

  RoomRepository get _repository =>
      widget.repository ?? GetIt.instance<RoomRepository>();

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

      // Busy protects only the asynchronous invite issuance. Keeping it true
      // while the dialog is open leaves an indeterminate progress indicator
      // animating behind the modal forever, which both wastes frames and makes
      // deterministic widget settling impossible.
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) =>
            _RoomInviteDialog(room: saved, invite: invite, copy: copy),
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

class _RoomInviteDialog extends StatelessWidget {
  const _RoomInviteDialog({
    required this.room,
    required this.invite,
    required this.copy,
  });

  final SavedRoom room;
  final RoomInvitation invite;
  final _InviteCopy copy;

  @override
  Widget build(BuildContext context) {
    final encoded = invite.encode();
    return Dialog(
      key: const Key('room-invite-dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, maxHeight: 560),
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
                        room.room.name,
                        key: const Key('room-invite-room-name'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        key: const Key('room-invite-qr'),
                        width: 216,
                        height: 216,
                        padding: const EdgeInsets.all(10),
                        color: Colors.white,
                        child: QrImageView(
                          data: encoded,
                          size: 196,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(color: Colors.black),
                          dataModuleStyle: const QrDataModuleStyle(
                            color: Colors.black,
                          ),
                          semanticsLabel: copy.qrSemantics,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(copy.codeLabel, style: const TextStyle(fontSize: 12)),
                      SelectableText(
                        invite.displayCode,
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
}
