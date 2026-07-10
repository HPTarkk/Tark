import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';

/// Transport picker, relocated here from Landing (item 5). WiFi and Hotspot
/// (item 9) merge into one entry — the host-vs-join choice now lives on the
/// combined WiFi/Hotspot page itself, not this picker.
class TransportModePicker extends StatelessWidget {
  const TransportModePicker({super.key});

  bool _isWifiGroup(TransferMode mode) =>
      mode == TransferMode.wifi || mode == TransferMode.hotspot;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final store = GetIt.instance<TransferModeStore>();
    return StreamBuilder<TransferMode>(
      initialData: store.mode,
      stream: store.modeChanges,
      builder: (context, snapshot) {
        final mode = snapshot.data ?? store.mode;
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              _ModeButton(
                label: s.transport_wifi_hotspot,
                icon: Icons.wifi_rounded,
                selected: _isWifiGroup(mode),
                // Leave an existing hotspot selection alone — only switch to
                // plain WiFi when coming from a different group entirely.
                onTap: () => store.setMode(
                  _isWifiGroup(mode) ? mode : TransferMode.wifi,
                ),
              ),
              _ModeButton(
                label: s.transport_bluetooth,
                icon: Icons.bluetooth_rounded,
                selected: mode == TransferMode.bluetooth,
                onTap: () => store.setMode(TransferMode.bluetooth),
              ),
              _ModeButton(
                label: s.transport_guest,
                icon: Icons.qr_code_rounded,
                selected: mode == TransferMode.guest,
                onTap: () => store.setMode(TransferMode.guest),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? AppColors.amber.withAlpha(25) : null,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border.all(color: AppColors.amber.withAlpha(140))
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? AppColors.amber : AppColors.textSecondary,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? AppColors.amber : AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
