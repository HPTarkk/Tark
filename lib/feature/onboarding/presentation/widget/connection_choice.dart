import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/beta/beta_badge.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../transfer/api/transfer_api.dart';

/// How the phone will connect, said once, quietly, with a way to change it.
///
/// This used to be a whole screen of its own. Almost nobody needs to touch
/// it — Wi-Fi/Hotspot is right for nearly everyone and Rooms work the rest
/// out themselves — so it is now a chip on the last step (the same chip
/// Landing shows) that opens the full choice only for the person who wants
/// it. Bluetooth, the free option, is always one of the rows.
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  /// The effective choice — Wi-Fi/Hotspot unless another was picked.
  final TransferMode mode;
  final ValueChanged<TransferMode> onChanged;

  static String label(AppLocalizations s, TransferMode mode) => switch (mode) {
    TransferMode.wifi || TransferMode.hotspot => s.transport_wifi_hotspot,
    TransferMode.bluetooth => s.transport_bluetooth,
    TransferMode.guest => s.transport_guest,
  };

  static IconData icon(TransferMode mode) => switch (mode) {
    TransferMode.wifi || TransferMode.hotspot => Icons.wifi_rounded,
    TransferMode.bluetooth => Icons.bluetooth_rounded,
    TransferMode.guest => Icons.qr_code_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Semantics(
      button: true,
      label: '${label(s, mode)}. ${s.onbx_change}',
      excludeSemantics: true,
      child: PressableScale(
        onTap: () => unawaited(_open(context)),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: AppMotion.card,
                child: Icon(
                  icon(mode),
                  key: ValueKey(icon(mode)),
                  size: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 6),
              if (mode.betaFeature != null) ...[
                const BetaPill(showIcon: false),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label(s, mode),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: AppColors.border,
              ),
              Text(
                s.onbx_change,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<TransferMode>(
      context: context,
      routeSettings: const RouteSettings(name: 'OnboardingConnection'),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (_) => _ConnectionSheet(current: mode),
    );
    if (picked == null || !context.mounted) return;
    // Same entitlement gate as Settings and the old transport screen: a
    // premium transport goes through the upgrade screen, which always offers
    // Bluetooth as the free alternative.
    if (picked.requiresPremium &&
        !GetIt.instance<LicenseGate>().allows(PremiumFeature.wifiTransport)) {
      final allowed = await openSubscriptionGate(
        context,
        PremiumFeature.wifiTransport,
        onFreeAlternative: () async => onChanged(TransferMode.bluetooth),
      );
      if (!allowed) return;
    }
    HapticFeedback.selectionClick();
    Sfx.play(SfxEvent.toggle);
    onChanged(picked);
  }
}

class _ConnectionSheet extends StatelessWidget {
  const _ConnectionSheet({required this.current});

  final TransferMode current;

  static bool _wifiGroup(TransferMode mode) =>
      mode == TransferMode.wifi || mode == TransferMode.hotspot;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final options = [
      (
        _wifiGroup(current) ? current : TransferMode.wifi,
        s.onboarding_mode_wifi_desc,
        _wifiGroup(current),
      ),
      (
        TransferMode.bluetooth,
        s.onboarding_mode_bluetooth_desc,
        current == TransferMode.bluetooth,
      ),
      (
        TransferMode.guest,
        s.onboarding_mode_guest_desc,
        current == TransferMode.guest,
      ),
    ];
    return SheetShell(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: StaggeredEntrance(
          children: [
            Text(
              s.onboarding_mode_title,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 16),
              child: Text(
                s.onboarding_mode_help,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  height: 1.55,
                ),
              ),
            ),
            for (final (mode, hint, selected) in options)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _Option(
                  key: ValueKey('connection-${mode.name}'),
                  icon: ConnectionChip.icon(mode),
                  beta: mode.betaFeature != null,
                  label: ConnectionChip.label(s, mode),
                  hint: hint,
                  selected: selected,
                  onTap: () => Navigator.of(context).pop(mode),
                ),
              ),
          ],
          builder: (context, children) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
    this.beta = false,
    super.key,
  });

  /// An experimental option: carries the Beta mark beside its name.
  final bool beta;
  final IconData icon;
  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? AppColors.amber : AppColors.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label. $hint',
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.amber.withValues(alpha: 0.10)
                : AppColors.fieldCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? AppColors.amber
                  : AppColors.amber.withValues(alpha: 0.22),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: accent, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: TextStyle(
                              color: accent,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        if (beta) ...[
                          const SizedBox(width: 8),
                          const BetaPill(showIcon: false),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hint,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: AppMotion.card,
                child: Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.amber,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
