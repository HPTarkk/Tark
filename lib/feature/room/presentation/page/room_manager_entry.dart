import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/routes.dart';
import 'room_list_page.dart';

/// Production entry for durable Room management.
///
/// Keeps the established Room list/create/manage surface intact while exposing
/// both halves of the secure offline invite handshake as explicit actions.
/// Neither action turns a short code or bearer QR into authorization: the join
/// route still requires the correlated issuer request/response round trip, and
/// the verify route still redeems only a capability issued by this device.
class RoomManagerEntry extends StatelessWidget {
  const RoomManagerEntry({super.key});

  static Widget buildPage() => const RoomManagerEntry();

  @override
  Widget build(BuildContext context) {
    final fa =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
    return Stack(
      children: [
        Positioned.fill(child: RoomListPage.buildPage()),
        SafeArea(
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FloatingActionButton.extended(
                    key: const Key('rooms-verify-join-request'),
                    heroTag: 'rooms-verify-join-request',
                    onPressed: () =>
                        context.push(AppRoutes.roomQrJoinIssuerPath),
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(fa ? 'تأیید درخواست' : 'Verify request'),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton.extended(
                    key: const Key('rooms-join-secure'),
                    heroTag: 'rooms-secure-join',
                    onPressed: () => context.push(AppRoutes.roomQrJoinPath),
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: Text(fa ? 'پیوستن با QR' : 'Join with QR'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
