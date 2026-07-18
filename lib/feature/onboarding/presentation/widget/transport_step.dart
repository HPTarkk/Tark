import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 3 — choose how peers connect, as a "network link" channel scan: three
/// console rows, one per transport family. Selecting one clips the matching
/// link module onto the radio.
class TransportStep extends StatelessWidget {
  final Animation<double> reveal;

  const TransportStep({super.key, required this.reveal});

  static bool _isWifiGroup(TransferMode mode) =>
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
                  icon: Icons.wifi_rounded,
                  label: s.transport_wifi_hotspot,
                  sublabel: s.onboarding_mode_wifi_desc,
                  selected: _isWifiGroup(state.mode),
                  onTap: () => _select(
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
                  onTap: () => _select(cubit, TransferMode.bluetooth),
                ),
                const SizedBox(height: 10),
                HudOption(
                  icon: Icons.qr_code_rounded,
                  label: s.transport_guest,
                  sublabel: s.onboarding_mode_guest_desc,
                  selected: state.mode == TransferMode.guest,
                  onTap: () => _select(cubit, TransferMode.guest),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _select(OnboardingCubit cubit, TransferMode mode) {
    HapticFeedback.selectionClick();
    Sfx.play(SfxEvent.toggle);
    cubit.selectMode(mode);
  }
}
