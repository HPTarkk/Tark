import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/routes.dart';
import 'room_list_page.dart';

/// Production entry for durable Room management.
///
/// Keeps the established Room list/create/manage surface intact while exposing
/// secure invite join as a separate explicit action. Joining never happens from
/// a short code or from merely scanning a bearer invite; the routed QR flow
/// still requires the correlated issuer request/response handshake.
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
              child: FloatingActionButton.extended(
                key: const Key('rooms-join-secure'),
                heroTag: 'rooms-secure-join',
                onPressed: () => context.push(AppRoutes.roomQrJoinPath),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: Text(fa ? 'پیوستن با QR' : 'Join with QR'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
