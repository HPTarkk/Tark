import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';

/// Wi-Fi / Hotspot segment switcher at the top of the combined page.
class HotspotSegmentedControl extends StatelessWidget {
  final WifiHotspotSegment segment;
  final ValueChanged<WifiHotspotSegment> onChanged;

  const HotspotSegmentedControl({
    super.key,
    required this.segment,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          _SegmentButton(
            label: s.transport_wifi,
            icon: Icons.wifi_rounded,
            selected: segment == WifiHotspotSegment.wifi,
            onTap: () => onChanged(WifiHotspotSegment.wifi),
          ),
          _SegmentButton(
            label: s.transport_hotspot,
            icon: Icons.wifi_tethering_rounded,
            selected: segment == WifiHotspotSegment.hotspot,
            onTap: () => onChanged(WifiHotspotSegment.hotspot),
          ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
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
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.amber.withAlpha(25) : null,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border.all(color: AppColors.amber.withAlpha(140))
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? AppColors.amber : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.amber : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
