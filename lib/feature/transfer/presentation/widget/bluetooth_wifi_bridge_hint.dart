import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/service/transfer_mode_store.dart';
import '../manager/bluetooth_connect_cubit.dart';

/// Tears down the Bluetooth session, switches the active transport to the
/// Wi-Fi hotspot bridge, and navigates there — the escape hatch for
/// iPhone↔Android pairs where Bluetooth is flaky.
Future<void> _switchToHotspot(BuildContext context) async {
  context.read<BluetoothConnectCubit>().backToRoleSelection();
  await GetIt.instance<TransferModeStore>().setMode(TransferMode.hotspot);
  if (context.mounted) {
    context.goNamed(
      AppRoutes.wifiHotspotName,
      queryParameters: const {'mode': 'hotspot'},
    );
  }
}

/// Cross-OS nudge: Bluetooth between iPhone and Android is unreliable, so this
/// offers a one-tap jump to the Wi-Fi hotspot bridge. Shown as always-on
/// guidance on the role screen and as a recovery card when BLE advertising
/// couldn't start while hosting.
class BluetoothWifiBridgeHint extends StatelessWidget {
  final String message;

  const BluetoothWifiBridgeHint({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withAlpha(14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.phone_iphone_rounded,
                color: AppColors.amber,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _switchToHotspot(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.amber.withAlpha(120),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.wifi_tethering_rounded,
                    color: AppColors.amber,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.bt_use_wifi_bridge,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
