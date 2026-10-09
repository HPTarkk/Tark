import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 4 — explicit transport choice, led by Wi-Fi/Hotspot.
class TransportStep extends StatelessWidget {
  final Animation<double> reveal;

  const TransportStep({super.key, required this.reveal});

  static bool _isWifiGroup(TransferMode? mode) =>
      mode == null || mode == TransferMode.wifi || mode == TransferMode.hotspot;

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
            status: '05·06',
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
                  icon: Icons.wifi_rounded,
                  label: s.transport_wifi_hotspot,
                  sublabel: s.onboarding_mode_wifi_desc,
                  selected: _isWifiGroup(state.mode),
                  onTap: () => _select(
                    context,
                    cubit,
                    _isWifiGroup(state.mode)
                        ? state.mode ?? TransferMode.wifi
                        : TransferMode.wifi,
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

  Future<void> _select(
    BuildContext context,
    OnboardingCubit cubit,
    TransferMode? mode,
  ) async {
    // Keep the same entitlement gate as Settings and offer Bluetooth only
    // through the user's explicit choice in the upgrade screen.
    if (mode != null &&
        mode.requiresPremium &&
        !GetIt.instance<LicenseGate>().allows(PremiumFeature.wifiTransport)) {
      if (!await openSubscriptionGate(
        context,
        PremiumFeature.wifiTransport,
        onFreeAlternative: () async {
          if (context.mounted) cubit.selectMode(TransferMode.bluetooth);
        },
      )) {
        return;
      }
    }
    if (!context.mounted) return;
    HapticFeedback.selectionClick();
    Sfx.play(SfxEvent.toggle);
    cubit.selectMode(mode);
  }
}
