import 'package:flutter/material.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';

/// Unified banner for [ConnectionHealthStatus]: a spinner while the transport
/// is auto-reconnecting, or a message + manual "Retry now" button once it's
/// given up (auto-reconnect disabled, or a bounded retry — e.g. Guest —
/// exhausted its attempts).
class ConnectionHealthBanner extends StatelessWidget {
  const ConnectionHealthBanner({
    super.key,
    required this.health,
    required this.transferMode,
    required this.onRetry,
  });

  final ConnectionHealthStatus health;
  final TransferMode transferMode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isBluetooth = transferMode == TransferMode.bluetooth;
    final isHealthy = health == ConnectionHealthStatus.healthy;
    final isReconnecting = health == ConnectionHealthStatus.reconnecting;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      child: isHealthy
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.amber.withAlpha(130)),
              ),
              child: Row(
                children: [
                  if (isReconnecting)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: AppColors.amber,
                        strokeWidth: 2,
                      ),
                    )
                  else
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 16,
                      color: AppColors.amber,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _message(s, isBluetooth, isReconnecting),
                      style: TextStyle(
                        color: AppColors.amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!isReconnecting)
                    TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.amber,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        s.retry,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  String _message(AppLocalizations s, bool isBluetooth, bool isReconnecting) {
    if (isReconnecting) {
      return isBluetooth ? s.bt_link_reconnecting : s.link_reconnecting;
    }
    return isBluetooth ? s.bt_link_down : s.link_down;
  }
}
