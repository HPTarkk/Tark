import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/billing_service.dart';
import '../../../../core/entitlement/signed_entitlement.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/entitlement/subscription_service.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/friendly_date.dart';
import '../../../update/data/store_launcher.dart';
import '../widget/auth_widgets.dart';

/// The signed-in person's own subscription: which plan, whether it renews
/// or ends and when, and that Bazaar takes the payment. Opens on what this
/// phone already knows and refreshes from the server in the background, so
/// it works offline and still shows the latest when online.
///
/// Cancelling and auto-renew live in Bazaar (its billing API has no way to
/// do either from inside the app), so the page sends people there.
class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage._();

  static const routeName = 'SubscriptionPage';

  static Widget buildPage() => const SubscriptionPage._();

  /// Tark's page in Bazaar; the website when the Bazaar app is missing.
  static final bazaarListing = Uri.parse(
    'https://cafebazaar.ir/app/com.b1101.tark',
  );

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  final SubscriptionService _subscription =
      GetIt.instance<SubscriptionService>();
  StreamSubscription<void>? _changes;

  /// Null while the refresh is running, then whether the server answered.
  bool? _reached;

  @override
  void initState() {
    super.initState();
    _changes = _subscription.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final reached = await _subscription.refresh();
    if (mounted) setState(() => _reached = reached);
  }

  Future<void> _openPlans() async {
    await openSubscriptionPlans(context);
    if (mounted) setState(() {});
  }

  Future<void> _openBazaar() async {
    final opened = await GetIt.instance<StoreLauncher>().openListing(
      SubscriptionPage.bazaarListing,
    );
    if (!opened && mounted) {
      showAuthToast(context, context.getString.auth_error_trouble);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final token = _subscription.entitlement;
    final status = token?.status ?? EntitlementStatus.none;
    final active =
        status == EntitlementStatus.active && _subscription.isPremiumActive;
    final hasHistory = token != null && status != EntitlementStatus.none;
    final gift = token?.sku == 'comp';

    return AuthScaffold(
      icon: Icons.workspace_premium_rounded,
      title: hasHistory ? s.mysub_title : s.mysub_none_title,
      body: hasHistory ? null : s.mysub_none_body,
      children: [
        if (hasHistory) ...[
          _PlanCard(
            key: const ValueKey('subscription-card'),
            title: _planTitle(context, token),
            status: _statusLine(context, token, active),
            paidVia: gift ? s.mysub_paid_gift : s.mysub_paid_bazaar,
            active: active,
            gift: gift,
          ),
          const SizedBox(height: 20),
        ],
        if (_reached == false) AuthMessage(s.mysub_offline),
        if (active && !gift) ...[
          AuthSecondaryButton(
            buttonKey: const ValueKey('subscription-open-bazaar'),
            label: s.mysub_manage,
            icon: Icons.storefront_rounded,
            onTap: _openBazaar,
          ),
          const SizedBox(height: 10),
          Text(
            s.mysub_manage_note,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ] else if (!active)
          AuthPrimaryButton(
            buttonKey: const ValueKey('subscription-see-plans'),
            label: hasHistory ? s.mysub_renew : s.mysub_see_plans,
            onTap: _openPlans,
          ),
        if (token != null) ...[
          const SizedBox(height: 18),
          Text(
            s.mysub_checked(FriendlyDate.format(context, token.issuedAt)),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary.withAlpha(170),
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  /// The server's name for the plan when it gave one; otherwise built from
  /// the product id, so the page still reads right offline.
  String _planTitle(BuildContext context, SignedEntitlement token) {
    final fromServer = _subscription.planTitle;
    if (fromServer != null) return fromServer;
    final s = context.getString;
    if (token.sku == 'comp') return s.mysub_paid_gift;
    final months = BillingPlan.monthsOf(token.sku ?? '');
    if (months == null) return s.mysub_premium;
    return months % 12 == 0
        ? s.mysub_plan_years(months ~/ 12)
        : s.mysub_plan_months(months);
  }

  String _statusLine(
    BuildContext context,
    SignedEntitlement token,
    bool active,
  ) {
    final s = context.getString;
    final until = token.until;
    if (until == null) return '';
    final date = FriendlyDate.format(context, until);
    return switch (token.status) {
      EntitlementStatus.refunded => s.mysub_refunded(date),
      EntitlementStatus.active when active && token.autoRenewing =>
        s.mysub_renews(date),
      EntitlementStatus.active when active => s.mysub_ends(date),
      _ => s.mysub_ended(date),
    };
  }
}

/// The plan, framed in amber with a PREMIUM badge while it runs, and plain
/// once it has ended.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.status,
    required this.paidVia,
    required this.active,
    required this.gift,
    super.key,
  });

  final String title;
  final String status;
  final String paidVia;
  final bool active;
  final bool gift;

  @override
  Widget build(BuildContext context) {
    final accent = active ? AppColors.amber : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? AppColors.amber.withAlpha(120) : AppColors.border,
          width: active ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(30),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_rounded, size: 14, color: AppColors.amber),
                  const SizedBox(width: 4),
                  Text(
                    context.getString.mysub_premium,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          if (active) const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (status.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              status,
              style: TextStyle(color: accent, fontSize: 14, height: 1.5),
            ),
          ],
          const SizedBox(height: 14),
          Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                gift ? Icons.card_giftcard_rounded : Icons.storefront_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  paidVia,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
