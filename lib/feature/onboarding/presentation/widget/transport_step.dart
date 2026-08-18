import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/paywall_sheet.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 3 — how peers connect, as a "network link" channel scan: four console
/// rows, the first of which hands the decision back to the app.
///
/// **AUTOMATIC leads and is pre-selected (P2 §1).** The beat used to open with
/// Wi-Fi already lit, which meant every first run ended by writing a transport
/// preference the user had not so much chosen as walked past — and a
/// preference beats the advisor by definition, so automatic would have been
/// dead on arrival for every new install. Leading with it inverts that: doing
/// nothing here is doing the right thing, and the three rows below stay for
/// the person who knows they want one.
class TransportStep extends StatelessWidget {
  final Animation<double> reveal;

  const TransportStep({super.key, required this.reveal});

  static bool _isWifiGroup(TransferMode? mode) =>
      mode == TransferMode.wifi || mode == TransferMode.hotspot;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      buildWhen: (p, c) => p.mode != c.mode,
      builder: (context, state) {
        final cubit = context.read<OnboardingCubit>();
        return StaggeredItem(
          reveal: reveal,
          index: 0,
          count: 1,
          child: HudPanel(
            header: s.onboarding_mode_title,
            status: '04·05',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.onboarding_mode_help,
                  style: const TextStyle(
                    color: Onb.textDim,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                HudOption(
                  icon: Icons.auto_awesome_rounded,
                  label: s.transport_automatic,
                  sublabel: s.onboarding_mode_auto_desc,
                  selected: state.mode == null,
                  onTap: () => _select(context, cubit, null),
                ),
                const SizedBox(height: 10),
                HudOption(
                  icon: Icons.wifi_rounded,
                  label: s.transport_wifi_hotspot,
                  sublabel: s.onboarding_mode_wifi_desc,
                  selected: _isWifiGroup(state.mode),
                  onTap: () => _select(
                    context,
                    cubit,
                    _isWifiGroup(state.mode) ? state.mode : TransferMode.wifi,
                  ),
                ),
                const SizedBox(height: 10),
                HudOption(
                  icon: Icons.bluetooth_rounded,
                  label: s.transport_bluetooth,
                  sublabel: s.onboarding_mode_bluetooth_desc,
                  selected: state.mode == TransferMode.bluetooth,
                  onTap: () => _select(context, cubit, TransferMode.bluetooth),
                ),
                const SizedBox(height: 10),
                HudOption(
                  icon: Icons.qr_code_rounded,
                  label: s.transport_guest,
                  sublabel: s.onboarding_mode_guest_desc,
                  selected: state.mode == TransferMode.guest,
                  onTap: () => _select(context, cubit, TransferMode.guest),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _select(
    BuildContext context,
    OnboardingCubit cubit,
    TransferMode? mode,
  ) {
    // Reachable in practice only after a trial has lapsed — a first run is
    // always inside the trial, so onboarding normally sees everything
    // unlocked. Gated anyway: the cubit persists this choice through
    // TransferModeStore.setPinnedMode at launch, which would silently refuse
    // it and leave a lit row that never took effect. Automatic is never
    // gated: it is the absence of a pin, and the advisor's own ladder ends on
    // free Bluetooth when nothing else is entitled.
    if (mode != null &&
        mode.requiresPremium &&
        !GetIt.instance<LicenseGate>().allows(PremiumFeature.wifiTransport)) {
      showPaywallSheet(context, PremiumFeature.wifiTransport);
      return;
    }
    HapticFeedback.selectionClick();
    Sfx.play(SfxEvent.toggle);
    cubit.selectMode(mode);
  }
}
