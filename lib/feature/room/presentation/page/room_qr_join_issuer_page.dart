import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/l10n/extension.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_acceptance_coordinator.dart';
import '../../domain/service/room_invite_join_exchange.dart';

/// Issuer-side half of the offline QR join handshake.
class RoomQrJoinIssuerPage extends StatefulWidget {
  const RoomQrJoinIssuerPage({
    required this.repository,
    this.identityLifecycle,
    super.key,
  });

  static Widget buildPage() =>
      RoomQrJoinIssuerPage(repository: GetIt.instance<RoomRepository>());

  final RoomRepository repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;

  @override
  State<RoomQrJoinIssuerPage> createState() => _RoomQrJoinIssuerPageState();
}

enum _IssuerStage { scanRequest, processing, response }

class _RoomQrJoinIssuerPageState extends State<RoomQrJoinIssuerPage> {
  late final RoomInviteJoinExchange _exchange;
  late final RoomTransportIdentityLifecycle _identityLifecycle;
  _IssuerStage _stage = _IssuerStage.scanRequest;
  String? _response;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _identityLifecycle =
        widget.identityLifecycle ??
        RoomTransportIdentityLifecycle(
          store: PlatformRoomTransportIdentitySecureStore(),
        );
    _exchange = RoomInviteJoinExchange(
      acceptance: RoomInviteAcceptanceCoordinator(widget.repository),
      issueCertificate:
          ({
            required acceptedRoom,
            required memberId,
            required memberPublicKey,
          }) => _identityLifecycle.issueMemberCertificate(
            issuerRoom: acceptedRoom,
            memberId: memberId,
            memberPublicKey: memberPublicKey,
          ),
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
          SnackBar(content: Text(context.getString.issuer_verify_failed)),
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
    appBar: AppBar(title: Text(context.getString.issuer_title)),
    body: SafeArea(
      child: switch (_stage) {
        _IssuerStage.scanRequest => Column(
          key: const Key('room-issuer-scan-request'),
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                context.getString.issuer_scan_hint,
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
              ? context.getString.issuer_accepted
              : context.getString.issuer_rejected,
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
          child: Text(context.getString.issuer_done),
        ),
      ],
    );
  }
}
