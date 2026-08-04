import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../l10n/extension.dart';
import '../theme/app_colors.dart';
import '../utils/extensions.dart';
import 'billing_service.dart';
import 'entitlement.dart';
import 'entitlement_store.dart';
import 'license_gate.dart';
import 'premium_feature.dart';

/// The one upgrade surface. Every denied [PremiumFeature] lands here rather
/// than dead-ending, which is the whole reason gates are checked in the UI
/// before the cubit rather than only inside it.
///
/// Prices are never composed here — they come from whatever the store
/// reports for each SKU ([BillingService.offers]), so a discount run in the
/// Bazaar console shows up without an app release. When billing is
/// unavailable the plans still render, without prices, above an honest note.
Future<void> showPaywallSheet(BuildContext context, PremiumFeature feature) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _PaywallSheet(feature: feature),
  );
}

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet({required this.feature});

  final PremiumFeature feature;

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  final BillingService _billing = GetIt.instance<BillingService>();
  final EntitlementStore _store = GetIt.instance<EntitlementStore>();
  final LicenseGate _gate = GetIt.instance<LicenseGate>();

  List<BillingPlanOffer> _offers = const [];
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _loadOffers();
  }

  Future<void> _loadOffers() async {
    final offers = _gate.canPurchase ? await _billing.offers() : <BillingPlanOffer>[];
    if (!mounted) return;
    setState(() {
      _offers = offers;
      _busy = false;
    });
  }

  Future<void> _purchase(BillingPlan plan) async {
    setState(() => _busy = true);
    final result = await _billing.purchase(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case PurchaseSuccess(:final entitlement):
        await _store.grant(entitlement);
        if (mounted) Navigator.of(context).pop();
      case PurchaseCancelled():
        break;
      case PurchaseFailed():
        _toast(context.getString.paywall_unavailable);
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final restored = await _billing.restore();
    if (!mounted) return;
    setState(() => _busy = false);
    final s = context.getString;
    if (restored == null) {
      _toast(s.paywall_restore_none);
      return;
    }
    await _store.grant(restored);
    if (!mounted) return;
    _toast(s.paywall_restored);
    Navigator.of(context).pop();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.card),
    );
  }

  String _reason(BuildContext context) {
    final s = context.getString;
    return switch (widget.feature) {
      PremiumFeature.wifiTransport => s.paywall_locked_wifi,
      PremiumFeature.selfMute => s.paywall_locked_mute,
      PremiumFeature.musicPlayback => s.paywall_locked_music,
    };
  }

  /// Trial line: how long is left, or that it has run out. Shown only while
  /// the trial is the active source — once a purchase lands there is nothing
  /// to count down.
  String? _trialLine(BuildContext context) {
    final s = context.getString;
    final current = _store.current;
    if (current.source != EntitlementSource.trial) return null;
    final left = current.remainingAt(_store.now);
    if (left == null || left == Duration.zero) return s.paywall_trial_over;
    // Round up: with 30 minutes left "1 day" reads better than "0 days".
    final days = left.inHours ~/ 24 + (left.inHours % 24 > 0 ? 1 : 0);
    return s.paywall_trial_left(days.localized(context));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final trial = _trialLine(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(Icons.workspace_premium_rounded,
                  color: AppColors.amber, size: 22),
              const SizedBox(width: 10),
              Text(
                s.paywall_title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _reason(context),
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (trial != null) ...[
            const SizedBox(height: 8),
            Text(
              trial,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.amber),
              ),
            )
          else
            for (final plan in BillingPlan.values) ...[
              _PlanRow(
                label: _planLabel(context, plan),
                price: _priceFor(plan),
                onTap: _offers.isEmpty ? null : () => _purchase(plan),
              ),
              const SizedBox(height: 8),
            ],
          if (!_busy && _offers.isEmpty) ...[
            const SizedBox(height: 4),
            Text(
              s.paywall_unavailable,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary.withAlpha(180),
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.bluetooth_rounded,
                  color: AppColors.textSecondary, size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.paywall_free_note,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: _busy || !_gate.canPurchase ? null : _restore,
                child: Text(
                  s.paywall_restore,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  s.paywall_close,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String? _priceFor(BillingPlan plan) {
    for (final offer in _offers) {
      if (offer.plan == plan) return offer.price;
    }
    return null;
  }

  String _planLabel(BuildContext context, BillingPlan plan) {
    final s = context.getString;
    return switch (plan) {
      BillingPlan.monthly => s.paywall_plan_1m,
      BillingPlan.sixMonth => s.paywall_plan_6m,
      BillingPlan.yearly => s.paywall_plan_12m,
      BillingPlan.lifetime => s.paywall_plan_lifetime,
    };
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.label, required this.price, this.onTap});

  final String label;
  final String? price;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: enabled ? AppColors.amber.withAlpha(90) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: enabled ? AppColors.textPrimary : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            if (price != null)
              Text(
                price!,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
