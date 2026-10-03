import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/billing_service.dart';
import '../../../../core/entitlement/signed_entitlement.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/entitlement/subscription_service.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
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
      showAuthToast(
        context,
        context.getString.auth_error_trouble,
        positive: false,
      );
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

    final Widget actions;
    if (active && !gift) {
      actions = Column(
        key: const ValueKey('manage'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthSecondaryButton(
            buttonKey: const ValueKey('subscription-open-bazaar'),
            label: s.mysub_manage,
            icon: Icons.storefront_rounded,
            onTap: _openBazaar,
          ),
          const SizedBox(height: 12),
          Text(
            s.mysub_manage_note,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      );
    } else if (!active) {
      actions = AuthPrimaryButton(
        key: const ValueKey('plans'),
        buttonKey: const ValueKey('subscription-see-plans'),
        label: hasHistory ? s.mysub_renew : s.mysub_see_plans,
        onTap: _openPlans,
      );
    } else {
      actions = const SizedBox(key: ValueKey('gift'), width: double.infinity);
    }

    return AuthScaffold(
      icon: Icons.workspace_premium_rounded,
      title: hasHistory ? s.mysub_title : s.mysub_none_title,
      body: hasHistory ? null : s.mysub_none_body,
      busy: _reached == null,
      children: [
        AuthReveal(
          visible: hasHistory,
          child: hasHistory
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: _PlanCard(
                    key: const ValueKey('subscription-card'),
                    title: _planTitle(context, token),
                    status: _statusLine(context, token, active),
                    paidVia: gift ? s.mysub_paid_gift : s.mysub_paid_bazaar,
                    active: active,
                    gift: gift,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        AuthMessageSlot(_reached == false ? s.mysub_offline : null),
        PhaseSwitcher(alignment: Alignment.center, child: actions),
        AuthReveal(
          visible: token != null,
          child: token == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    s.mysub_checked(
                      FriendlyDate.format(context, token.issuedAt),
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary.withValues(alpha: 0.7),
                      fontSize: 11.5,
                    ),
                  ),
                ),
        ),
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
    final amber = AppColors.amber;
    final accent = active ? amber : AppColors.textSecondary;
    return AnimatedContainer(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      padding: const EdgeInsetsDirectional.fromSTEB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [
            active
                ? Color.alphaBlend(
                    amber.withValues(alpha: 0.16),
                    AppColors.card,
                  )
                : AppColors.card,
            AppColors.card,
          ],
        ),
        border: Border.all(
          color: active ? amber.withValues(alpha: 0.5) : AppColors.border,
          width: active ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: amber.withValues(alpha: active ? 0.14 : 0),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (active) ...[
                      _PremiumBadge(label: context.getString.mysub_premium),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      title,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.14),
                ),
                child: Icon(
                  gift
                      ? Icons.card_giftcard_rounded
                      : Icons.workspace_premium_rounded,
                  color: accent,
                  size: 24,
                ),
              ),
            ],
          ),
          if (status.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  active ? Icons.autorenew_rounded : Icons.event_busy_rounded,
                  size: 16,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    status,
                    style: TextStyle(color: accent, fontSize: 14, height: 1.5),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Container(height: 1, color: AppColors.border),
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

/// PREMIUM, with a star, in an amber pill.
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 10, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: [
            amber.withValues(alpha: 0.26),
            amber.withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: amber.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 14, color: amber),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: amber,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: authLabelSpacing(context, 1.2),
            ),
          ),
        ],
      ),
    );
  }
}
