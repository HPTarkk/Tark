import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_acceptance_coordinator.dart';
import '../../domain/service/room_invite_join_exchange.dart';

/// Issuer-side half of the offline QR join handshake.
///
/// A scanned request is never trusted by the UI. It is passed to
/// [RoomInviteJoinExchange], which verifies/redeems the embedded invitation via
/// the canonical issuer ledger before an accepted response can be produced.
class RoomQrJoinIssuerPage extends StatefulWidget {
  const RoomQrJoinIssuerPage({required this.repository, super.key});

  static Widget buildPage() =>
      RoomQrJoinIssuerPage(repository: GetIt.instance<RoomRepository>());

  final RoomRepository repository;

  @override
  State<RoomQrJoinIssuerPage> createState() => _RoomQrJoinIssuerPageState();
}

enum _IssuerStage { scanRequest, processing, response }

class _RoomQrJoinIssuerPageState extends State<RoomQrJoinIssuerPage> {
  late final RoomInviteJoinExchange _exchange;
  _IssuerStage _stage = _IssuerStage.scanRequest;
  String? _response;
  bool _handling = false;

  bool get _fa =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';

  @override
  void initState() {
    super.initState();
    _exchange = RoomInviteJoinExchange(
      acceptance: RoomInviteAcceptanceCoordinator(widget.repository),
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || _stage != _IssuerStage.scanRequest) return;
    final encoded = _firstValue(capture);
    if (encoded == null) return;
    _handling = true;
    setState(() => _stage = _IssuerStage.processing);
    try {
      final response = await _exchange.handleEncodedRequest(
        encoded,
        now: DateTime.now().toUtc(),
      );
      if (!mounted) return;
      setState(() {
        _response = response;
        _stage = _IssuerStage.response;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _stage = _IssuerStage.scanRequest);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              _fa
                  ? 'بررسی درخواست ممکن نشد. دوباره اسکن کنید.'
                  : 'Could not verify the request. Scan again.',
            ),
          ),
        );
    } finally {
      _handling = false;
    }
  }

  String? _firstValue(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_fa ? 'تأیید درخواست همراه' : 'Verify rider request'),
    ),
    body: SafeArea(
      child: switch (_stage) {
        _IssuerStage.scanRequest => Column(
          key: const Key('room-issuer-scan-request'),
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _fa
                    ? 'QR درخواست عضویت روی گوشی همراه را اسکن کنید. فقط دعوت معتبر و مصرف‌نشده تأیید می‌شود.'
                    : 'Scan the membership-request QR on the rider phone. Only a valid, unredeemed invite can be accepted.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(child: MobileScanner(onDetect: _onDetect)),
          ],
        ),
        _IssuerStage.processing => const Center(
          child: CircularProgressIndicator(),
        ),
        _IssuerStage.response => _responseView(),
      },
    ),
  );

  Widget _responseView() {
    final response = _response!;
    final decoded = RoomInviteJoinResponse.decode(response);
    final accepted = decoded.status == RoomInviteJoinResponseStatus.accepted;
    return ListView(
      key: const Key('room-issuer-response-qr'),
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          accepted
              ? (_fa
                    ? 'درخواست تأیید شد. همراه باید این QR پاسخ را اسکن کند تا عضویت روی گوشی خودش ذخیره شود.'
                    : 'Request verified. The rider must scan this response QR before membership is saved on their phone.')
              : (_fa
                    ? 'درخواست تأیید نشد. این پاسخ فقط نتیجه رد را منتقل می‌کند.'
                    : 'Request was not verified. This response only carries the rejection result.'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            width: 260,
            height: 260,
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: QrImageView(
              data: response,
              size: 236,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(color: Colors.black),
              dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('room-issuer-done'),
          onPressed: () => Navigator.of(context).pop(accepted),
          child: Text(_fa ? 'تمام' : 'Done'),
        ),
      ],
    );
  }
}
