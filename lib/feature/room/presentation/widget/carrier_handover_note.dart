import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/service/room_carrier_promotion_controller.dart';
import 'carrier_status_scope.dart';

/// The only thing the carrier handover ever says out loud.
///
/// Everything underneath this widget — electing a host, raising an access
/// point, signing an announcement, moving every phone across — is machinery
/// the rider must never have to think about. They are wearing gloves and
/// looking at a road. So this says one short sentence, in the language of
/// *staying connected*, and never the words network, hotspot, Wi-Fi, SSID or
/// transport.
///
/// It earns its place in two moments and no others:
///
///  * While the move is happening, because something is about to change and a
///    second of silent reconfiguration reads as a fault.
///  * Afterwards, and only on the phone that became the radio, because that
///    phone has genuinely given up its internet connection and the person
///    holding it is owed that fact rather than left to discover it when a
///    message fails to send.
///
/// Every other phone sees nothing at all, ever, which is the point.
class CarrierHandoverNote extends StatelessWidget {
  const CarrierHandoverNote({super.key});

  @override
  Widget build(BuildContext context) {
    final source = CarrierStatusScope.of(context);
    if (source == null) return const SizedBox.shrink();
    return StreamBuilder<RoomCarrierStatus>(
      stream: source.statusChanges,
      initialData: source.status,
      builder: (context, snapshot) {
        final status = snapshot.data;
        final copy = status == null ? null : _CarrierCopy.of(context, status);
        // Grows and fades rather than appearing: this sits in a column of
        // banners above the mic control, and a line that pops in shoves the
        // primary control down by its full height in one frame.
        return AnimatedSize(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: AppMotion.card,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            child: copy == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    key: ValueKey<String>(copy.text),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _Note(copy: copy),
                  ),
          ),
        );
      },
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.copy});

  final _CarrierCopy copy;

  @override
  Widget build(BuildContext context) {
    final accent = copy.working ? AppColors.amber : AppColors.textSecondary;
    return Container(
      key: const Key('carrier-handover-note'),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: accent.withValues(alpha: 0.34)),
      ),
      child: Row(
        children: [
          if (copy.working)
            SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            )
          else
            Icon(Icons.cell_tower_rounded, size: 17, color: accent),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              copy.text,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What to say, if anything.
final class _CarrierCopy {
  const _CarrierCopy({required this.text, required this.working});

  /// Null when this phone has nothing worth saying — which is most of the
  /// time, on most phones.
  static _CarrierCopy? of(BuildContext context, RoomCarrierStatus status) {
    final fa =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
    switch (status.stage) {
      case RoomCarrierStage.raising:
      case RoomCarrierStage.moving:
        if (status.localIsHost) {
          return _CarrierCopy(
            working: true,
            text: fa
                ? 'داریم آماده می‌شویم که وقتی راه افتادید ارتباط قطع نشود. این گوشی مرکز ارتباط می‌شود.'
                : 'Getting you set up to stay connected once you set off. '
                      'This phone becomes the hub.',
          );
        }
        return _CarrierCopy(
          working: true,
          text: fa
              ? 'داریم آماده می‌شویم که وقتی راه افتادید ارتباط قطع نشود.'
              : 'Getting you set up to stay connected once you set off.',
        );
      case RoomCarrierStage.awaitingHost:
        return _CarrierCopy(
          working: true,
          text: fa
              ? 'یک لحظه — داریم ارتباط را برای بیرون آماده می‌کنیم.'
              : 'One moment — getting the room ready for the road.',
        );
      case RoomCarrierStage.settled:
        // The resting note, and the one fact that genuinely matters: this
        // phone is the hub, so it has no internet until the room closes.
        // Everyone else gets nothing, because for them nothing has changed.
        if (!status.localIsHost) return null;
        return _CarrierCopy(
          working: false,
          text: fa
              ? 'این گوشی مرکز ارتباط اتاق است. تا وقتی اتاق باز باشد، اینترنت این گوشی خاموش می‌ماند.'
              : 'This phone is the hub for the room. It stays off the internet '
                    'until the room closes.',
        );
    }
  }

  final String text;

  /// Whether something is happening right now, as opposed to a standing fact.
  final bool working;
}
