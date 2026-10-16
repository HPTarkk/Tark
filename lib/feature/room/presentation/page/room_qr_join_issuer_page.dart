import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/scene_turn.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/state_emblems.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_acceptance_coordinator.dart';
import '../../domain/service/room_invite_join_exchange.dart';
import '../../../../core/widget/status_note.dart';

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
      showStatusNote(
        context,
        context.getString.issuer_verify_failed,
        tone: StatusTone.problem,
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
      // Each step turns into the next as one card, like every other
      // connection screen, rather than cutting.
      child: SceneTurn(
        motion: SceneMotion.axis,
        scene: _stage,
        depth: _stage.index,
        child: switch (_stage) {
          _IssuerStage.scanRequest => _scanView(),
          _IssuerStage.processing => const Center(child: SignalLoader()),
          _IssuerStage.response => _responseView(),
        },
      ),
    ),
  );

  Widget _scanView() => Column(
    key: const Key('room-issuer-scan-request'),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
        child: SceneReflow(
          index: 0,
          child: Text(
            context.getString.issuer_scan_hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              height: 1.45,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AppColors.amber.withAlpha(120)),
              boxShadow: [
                BoxShadow(color: AppColors.amber.withAlpha(36), blurRadius: 28),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(27),
              child: MobileScanner(onDetect: _onDetect),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _responseView() {
    final response = _response!;
    final decoded = RoomInviteJoinResponse.decode(response);
    final accepted = decoded.status == RoomInviteJoinResponseStatus.accepted;
    final tone = accepted ? AppColors.green : AppColors.red;
    return ListView(
      key: const Key('room-issuer-response-qr'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      children: [
        SceneReflow(
          index: 0,
          child: Center(
            child: accepted
                ? const SettledEmblem(size: 72)
                : SnappedLinkEmblem(width: 104, height: 64, color: tone),
          ),
        ),
        const SizedBox(height: 16),
        SceneReflow(
          index: 1,
          child: Text(
            accepted
                ? context.getString.issuer_accepted
                : context.getString.issuer_rejected,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 22),
        SceneReflow(
          index: 2,
          child: Center(
            child: Container(
              width: 260,
              height: 260,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: tone.withAlpha(70),
                    blurRadius: 30,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: QrImageView(
                data: response,
                size: 236,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SceneReflow(
          index: 3,
          child: FilledButton(
            key: const Key('room-issuer-done'),
            onPressed: () => Navigator.of(context).pop(accepted),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(context.getString.issuer_done),
          ),
        ),
      ],
    );
  }
}
