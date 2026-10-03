import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_session.dart';
import '../config/support_config.dart';
import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../router/routes.dart';
import '../theme/app_colors.dart';
import '../utils/extensions.dart';
import '../widget/status_hero.dart';
import '../utils/friendly_date.dart';
import '../utils/logger.dart';
import 'billing_service.dart';
import 'license_gate.dart';
import 'plan_catalog.dart';
import 'plan_pricing.dart';
import 'premium_feature.dart';
import 'subscription_policy.dart';
import 'subscription_service.dart';

/// The one door every paid feature opens. Returns true when the feature may
/// go ahead — already unlocked, or unlocked on this screen.
///
/// Every locked tap lands here rather than dead-ending, which is why gates
/// are checked in the UI before the cubit rather than only inside it.
Future<bool> openSubscriptionGate(
  BuildContext context,
  PremiumFeature feature,
) async {
  final gate = GetIt.instance<LicenseGate>();
  if (gate.allows(feature)) return true;
  final granted = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      settings: const RouteSettings(name: 'SubscriptionGate'),
      fullscreenDialog: true,
      builder: (_) => SubscriptionGatePage(feature: feature),
    ),
  );
  return granted ?? false;
}

/// The same screen opened from the subscription page rather than a locked
/// feature: no feature to name, just the plans. True when premium is
/// unlocked on it.
Future<bool> openSubscriptionPlans(BuildContext context) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'SubscriptionGate'),
        fullscreenDialog: true,
        builder: (_) => const SubscriptionGatePage(),
      ),
    ) ??
    false;

/// One screen, driven entirely by state: it opens on "checking", asks the
/// server once, and becomes whichever answer came back — the plain renewal
/// screen, or one of the three "couldn't check" screens. Each state morphs
/// into the next in place instead of swapping pages, so a retry that works
/// reads as the same screen resolving, not as a new one appearing.
///
/// The copy never implies wrongdoing. Every state says what we know, what we
/// could not do, and the one thing that would fix it — and free features are
/// always a tap away.
class SubscriptionGatePage extends StatefulWidget {
  const SubscriptionGatePage({this.feature, super.key});

  /// The locked feature that was tapped; null when opened to see the plans.
  final PremiumFeature? feature;

  @override
  State<SubscriptionGatePage> createState() => _SubscriptionGatePageState();
}

sealed class _View {
  const _View();
}

class _Checking extends _View {
  const _Checking();
}

class _Resolved extends _View {
  const _Resolved(this.outcome);
  final GateOutcome outcome;
}

class _SubscriptionGatePageState extends State<SubscriptionGatePage> {
  final SubscriptionService _subscription =
      GetIt.instance<SubscriptionService>();
  final BillingService _billing = GetIt.instance<BillingService>();
  final PlanCatalog _plans = GetIt.instance<PlanCatalog>();

  _View _view = const _Checking();
  List<PlanPricing> _plansOnSale = const [];
  String? _selected;
  bool _busy = false;

  /// Long enough that "checking" is read rather than flashed; a check that
  /// answers in 40 ms and cuts straight to a result looks like a glitch.
  static const _minimumCheck = Duration(milliseconds: 650);

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    setState(() => _view = const _Checking());
    final results = await Future.wait([
      _subscription.check(),
      Future<void>.delayed(_minimumCheck),
    ]);
    if (!mounted) return;
    await _resolve(results.first as GateOutcome);
  }

  Future<void> _resolve(GateOutcome outcome) async {
    if (outcome is GateSubscribe) {
      final offers = await _billing.offers(await _plans.load());
      if (!mounted) return;
      _plansOnSale = PlanPricing.of(offers);
      if (!_plansOnSale.any((p) => p.sku == _selected)) {
        _selected = PlanPricing.preselect(_plansOnSale);
      }
    }
    // A granted outcome leaves on its own once the hero's check mark has
    // landed (see [_heroFor]).
    setState(() => _view = _Resolved(outcome));
  }

  PlanPricing? get _selectedPlan {
    for (final p in _plansOnSale) {
      if (p.sku == _selected) return p;
    }
    return null;
  }

  void _select(String sku) {
    if (_busy || sku == _selected) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _selected = sku);
  }

  Future<void> _buySelected() async {
    final plan = _selectedPlan?.offer.plan;
    if (plan != null && !_busy) await _purchase(plan);
  }

  Future<void> _purchase(BillingPlan plan) async {
    setState(() => _busy = true);
    final result = await _billing.purchase(plan);
    if (!mounted) return;
    switch (result) {
      case PurchaseSuccess(:final purchase):
        setState(() => _view = const _Checking());
        final outcome = await _subscription.submitBazaarPurchase(
          sku: purchase.sku,
          purchaseToken: purchase.purchaseToken,
        );
        if (!mounted) return;
        setState(() => _busy = false);
        await _resolve(outcome);
      case PurchaseCancelled():
        setState(() => _busy = false);
      case PurchaseFailed(:final message):
        Logger.log('Subscription: purchase failed ($message)');
        setState(() => _busy = false);
        _toast(context.getString.paywall_unavailable);
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final owned = await _billing.restore();
    if (!mounted) return;
    if (owned.isEmpty) {
      setState(() => _busy = false);
      _toast(context.getString.paywall_restore_none);
      return;
    }
    setState(() => _view = const _Checking());
    GateOutcome outcome = const GateSubscribe();
    for (final purchase in owned) {
      outcome = await _subscription.submitBazaarPurchase(
        sku: purchase.sku,
        purchaseToken: purchase.purchaseToken,
      );
      if (outcome is GateGranted) break;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _resolve(outcome);
  }

  /// A subscription belongs to an account: sign in (optional everywhere
  /// else in Tark), then ask the server again.
  Future<void> _signIn() async {
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    final signedIn = await router.pushNamed<bool>(AppRoutes.signInName);
    if (signedIn == true && mounted) await _check();
  }

  static bool get _canSignIn =>
      GetIt.instance.isRegistered<AccountSession>() &&
      GetIt.instance<AccountSession>().available;

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        elevation: 0,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.border),
        ),
        content: Row(
          children: [
            Icon(Icons.info_rounded, color: AppColors.amber, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The one hero the screen keeps through every state: it circles while
  /// the server is asked, changes its mark for each answer, and lands a
  /// check mark (then leaves) once premium is unlocked.
  Widget _heroFor(_View view) {
    final outcome = view is _Resolved ? view.outcome : null;
    final icon = switch (outcome) {
      null ||
      GateSubscribe() ||
      GateGranted() => Icons.workspace_premium_rounded,
      GateCouldNotCheck(:final reason) => switch (reason) {
        CheckReason.noData => Icons.cloud_sync_rounded,
        CheckReason.expired => Icons.event_repeat_rounded,
        CheckReason.staleCheck => Icons.wifi_tethering_rounded,
      },
      GateSignInRequired() => Icons.account_circle_outlined,
      GatePurchaseOwnedElsewhere() => Icons.swap_horiz_rounded,
    };
    return StatusHero(
      icon: icon,
      color: AppColors.amber,
      busy: view is _Checking || _busy,
      success: outcome is GateGranted,
      onSuccessShown: () {
        if (mounted) Navigator.of(context).pop(true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final granted = view is _Resolved && view.outcome is GateGranted;
    final selected = _selectedPlan;
    final checkout =
        view is _Resolved && view.outcome is GateSubscribe && selected != null;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // The same warm wash as the account screens, cooling to green once
          // premium is unlocked. A static gradient crossfaded by colour.
          Positioned.fill(
            child: AnimatedContainer(
              duration: AppMotion.entrance,
              curve: AppMotion.easeOut,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.78),
                  radius: 0.9,
                  colors: [
                    (granted ? AppColors.green : AppColors.amber).withValues(
                      alpha: 0.14,
                    ),
                    AppColors.background.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(end: 4, top: 4),
                    child: IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppColors.textSecondary,
                      ),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(child: _heroFor(view)),
                        PhaseSwitcher(
                          child: switch (view) {
                            _Checking() => const _CheckingState(
                              key: ValueKey('checking'),
                            ),
                            _Resolved(:final outcome) => KeyedSubtree(
                              key: ValueKey(outcome.runtimeType),
                              child: _buildOutcome(context, outcome),
                            ),
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                // The buy button stays in reach however far the plans
                // scroll; it rises in once there is something to buy.
                AnimatedSwitcher(
                  duration: AppMotion.reduced(context)
                      ? Duration.zero
                      : AppMotion.entrance,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.leaving,
                  transitionBuilder: (child, animation) => SizeTransition(
                    sizeFactor: animation,
                    alignment: AlignmentDirectional.topCenter,
                    child: FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.35),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                  ),
                  child: checkout
                      ? _CheckoutBar(
                          key: const ValueKey('checkout'),
                          plan: selected,
                          busy: _busy,
                          onBuy: _buySelected,
                          onRestore: _restore,
                        )
                      : const SizedBox(
                          key: ValueKey('no-checkout'),
                          width: double.infinity,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOutcome(BuildContext context, GateOutcome outcome) {
    final s = context.getString;
    return switch (outcome) {
      GateGranted() => _GrantedState(label: s.sub_granted),
      GateCouldNotCheck() => _CouldNotCheckState(
        outcome: outcome,
        onRetry: _check,
      ),
      GateSubscribe(:final endedAt) => _SubscribeState(
        feature: widget.feature,
        endedAt: endedAt,
        plans: _plansOnSale,
        selected: _selected,
        busy: _busy,
        onSelect: _select,
      ),
      GateSignInRequired() => _MessageState(
        title: s.sub_signin_title,
        body: s.sub_signin_body,
        action: _canSignIn ? s.sub_signin_action : null,
        onAction: _signIn,
      ),
      GatePurchaseOwnedElsewhere() => _MessageState(
        title: s.sub_owned_title,
        body: s.sub_owned_body,
        showSupport: true,
      ),
    };
  }
}

/// Letter spacing for the uppercase English labels. Persian is a joined
/// script, and spacing its letters pulls every word apart.
double _labelSpacing(BuildContext context, double latin) =>
    Directionality.of(context) == TextDirection.rtl ? 0 : latin;

/// The line under the hero while the one request is in flight; the hero's
/// arc carries the motion.
class _CheckingState extends StatelessWidget {
  const _CheckingState({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        context.getString.sub_checking,
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
      ),
    );
  }
}

class _GrantedState extends StatelessWidget {
  const _GrantedState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _CouldNotCheckState extends StatelessWidget {
  const _CouldNotCheckState({required this.outcome, required this.onRetry});

  final GateCouldNotCheck outcome;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final trouble = outcome.serviceTrouble;
    String date(DateTime? value) =>
        value == null ? '' : FriendlyDate.format(context, value);

    final (title, body) = switch (outcome.reason) {
      CheckReason.noData => (
        s.sub_nodata_title,
        trouble ? s.sub_nodata_body_trouble : s.sub_nodata_body_offline,
      ),
      CheckReason.expired => (
        s.sub_expired_title,
        trouble
            ? s.sub_expired_body_trouble(date(outcome.endedAt))
            : s.sub_expired_body_offline(date(outcome.endedAt)),
      ),
      CheckReason.staleCheck => (
        s.sub_stale_title,
        trouble
            ? s.sub_stale_body_trouble(date(outcome.lastCheckedAt))
            : s.sub_stale_body_offline(date(outcome.lastCheckedAt)),
      ),
    };

    return _StateLayout(
      title: title,
      body: body,
      footer: [
        _PrimaryButton(label: s.sub_try_again, onTap: onRetry, glow: true),
        const SizedBox(height: 18),
        const _SupportCard(),
        const SizedBox(height: 16),
        _FreeNote(text: s.sub_free_meanwhile),
      ],
    );
  }
}

class _SubscribeState extends StatelessWidget {
  const _SubscribeState({
    required this.feature,
    required this.endedAt,
    required this.plans,
    required this.selected,
    required this.busy,
    required this.onSelect,
  });

  final PremiumFeature? feature;
  final DateTime? endedAt;
  final List<PlanPricing> plans;
  final String? selected;
  final bool busy;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final ended = endedAt;
    final reason = switch (feature) {
      PremiumFeature.wifiTransport => s.paywall_locked_wifi,
      PremiumFeature.selfMute => s.paywall_locked_mute,
      PremiumFeature.musicPlayback => s.paywall_locked_music,
      null => s.mysub_none_body,
    };

    return _StateLayout(
      title: ended == null ? s.paywall_title : s.sub_renew_title,
      body: ended == null
          ? reason
          : s.sub_renew_body(FriendlyDate.format(context, ended)),
      footer: [
        _Perks(highlight: feature),
        const SizedBox(height: 20),
        // Only plans Bazaar has a price for: a plan shown without one could
        // not be bought anyway. Tapping a plan only selects it; the pinned
        // button buys.
        // The best value leads, preselected, so the plan the button buys is
        // in view on any phone; the rest keep the server's order.
        for (final plan in [
          ...plans.where((p) => p.bestValue),
          ...plans.where((p) => !p.bestValue),
        ]) ...[
          _PlanOption(
            pricing: plan,
            selected: plan.sku == selected,
            enabled: !busy,
            onTap: () => onSelect(plan.sku),
          ),
          const SizedBox(height: 12),
        ],
        if (plans.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text(
              s.paywall_unavailable,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary.withValues(alpha: 0.75),
                fontSize: 12,
              ),
            ),
          ),
        const SizedBox(height: 6),
        _FreeNote(text: s.paywall_free_note),
      ],
    );
  }
}

/// A plan's length in words: "3 months", "1 year", or the server's name for
/// the test plan.
String _planLength(BuildContext context, BillingPlan plan) {
  final s = context.getString;
  return switch (plan.months) {
    0 => plan.title,
    1 => s.paywall_month,
    12 => s.paywall_year,
    final m => s.paywall_months('$m'.localized(context)),
  };
}

/// What premium unlocks, as three tiles side by side. The feature that was
/// just tapped is lit, so the person sees the thing they reached for.
class _Perks extends StatelessWidget {
  const _Perks({required this.highlight});

  final PremiumFeature? highlight;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final perks = [
      (PremiumFeature.wifiTransport, Icons.wifi_rounded, s.paywall_perk_wifi),
      (PremiumFeature.selfMute, Icons.mic_off_rounded, s.paywall_perk_mute),
      (
        PremiumFeature.musicPlayback,
        Icons.music_note_rounded,
        s.paywall_perk_music,
      ),
    ];
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (feature, icon, label)) in perks.indexed) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: _PerkTile(
                icon: icon,
                label: label,
                lit: feature == highlight,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PerkTile extends StatelessWidget {
  const _PerkTile({required this.icon, required this.label, required this.lit});

  final IconData icon;
  final String label;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: lit
            ? Color.alphaBlend(amber.withValues(alpha: 0.12), AppColors.card)
            : AppColors.card,
        border: Border.all(
          color: lit ? amber.withValues(alpha: 0.7) : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: amber.withValues(alpha: lit ? 0.26 : 0.14),
            ),
            child: Icon(icon, size: 18, color: amber),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11.5,
              height: 1.45,
              fontWeight: lit ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.title,
    required this.body,
    this.showSupport = false,
    this.action,
    this.onAction,
  });

  final String title;
  final String body;
  final bool showSupport;

  /// An optional primary button (e.g. "Sign in").
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final label = action;
    final onTap = onAction;
    return _StateLayout(
      title: title,
      body: body,
      footer: [
        if (label != null && onTap != null) ...[
          _PrimaryButton(label: label, onTap: onTap, glow: true),
          const SizedBox(height: 18),
        ],
        if (showSupport) const _SupportCard(),
        const SizedBox(height: 16),
        _FreeNote(text: context.getString.sub_free_meanwhile),
      ],
    );
  }
}

/// Shared skeleton for every resolved state under the hero: heading, body,
/// then the state's own actions, arriving in the app's usual stagger.
class _StateLayout extends StatelessWidget {
  const _StateLayout({
    required this.title,
    required this.body,
    required this.footer,
  });

  final String title;
  final String body;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    return StaggeredEntrance(
      builder: (context, items) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: items,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 24,
              height: 1.25,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 26),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.7,
            ),
          ),
        ),
        ...footer,
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.glow = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    final amber = AppColors.amber;
    return PulseGlow(
      enabled: glow,
      borderRadius: radius,
      child: PressableScale(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: AlignmentDirectional.centerStart,
              end: AlignmentDirectional.centerEnd,
              colors: [amber, Color.lerp(amber, Colors.deepOrange, 0.35)!],
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.background,
              fontSize: 14.5,
              fontWeight: FontWeight.w900,
              letterSpacing: _labelSpacing(context, 1.2),
            ),
          ),
        ),
      ),
    );
  }
}

/// The support address, always tappable. Built in rather than fetched: this
/// card exists for exactly the moments the phone may be offline.
class _SupportCard extends StatelessWidget {
  const _SupportCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.sub_support_prompt,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          PressableScale(
            onTap: () =>
                launchUrl(SupportConfig.mailto(subject: s.sub_email_subject)),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.amber.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    Icons.mail_outline_rounded,
                    size: 17,
                    color: AppColors.amber,
                  ),
                ),
                const SizedBox(width: 10),
                // An address is an identifier: always left-to-right, even
                // inside a Persian layout.
                Flexible(
                  child: Text(
                    SupportConfig.email,
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.amber.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FreeNote extends StatelessWidget {
  const _FreeNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.bluetooth_rounded, color: AppColors.textSecondary, size: 15),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// One plan to pick: its length, the store's price, and for longer plans
/// what a month comes to and how much that saves. The best value wears a
/// ribbon. Selecting lights the border and fills the radio; it never buys.
class _PlanOption extends StatelessWidget {
  const _PlanOption({
    required this.pricing,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final PlanPricing pricing;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final amber = AppColors.amber;
    final radius = BorderRadius.circular(20);
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.card;
    final perMonth = pricing.perMonth;
    final saving = pricing.savingPercent;
    final card = Semantics(
      button: true,
      selected: selected,
      child: PressableScale(
        key: ValueKey('plan-${pricing.sku}'),
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.easeOut,
          padding: EdgeInsetsDirectional.fromSTEB(
            14,
            pricing.bestValue ? 18 : 14,
            16,
            14,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            color: selected
                ? Color.alphaBlend(
                    amber.withValues(alpha: 0.11),
                    AppColors.card,
                  )
                : AppColors.card,
            border: Border.all(
              color: selected ? amber : AppColors.border,
              width: 1.6,
            ),
            boxShadow: [
              BoxShadow(
                color: amber.withValues(alpha: selected ? 0.24 : 0),
                blurRadius: 24,
                spreadRadius: -6,
              ),
            ],
          ),
          child: Row(
            children: [
              _Radio(selected: selected),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _planLength(context, pricing.offer.plan),
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (perMonth != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        s.paywall_per_month(perMonth),
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: duration,
                    curve: AppMotion.easeOut,
                    style: DefaultTextStyle.of(context).style.copyWith(
                      color: selected ? amber : AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                    child: Text(pricing.offer.price),
                  ),
                  if (saving != null) ...[
                    const SizedBox(height: 5),
                    _SaveChip(percent: saving),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!pricing.bestValue) return card;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          PositionedDirectional(
            top: -10,
            end: 18,
            child: _Ribbon(text: s.paywall_best_value),
          ),
        ],
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.card;
    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.easeOut,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? amber : Colors.transparent,
        border: Border.all(
          color: selected
              ? amber
              : AppColors.textSecondary.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      child: AnimatedScale(
        scale: selected ? 1 : 0,
        duration: duration,
        curve: AppMotion.easeOut,
        child: Icon(Icons.check_rounded, size: 15, color: AppColors.background),
      ),
    );
  }
}

class _SaveChip extends StatelessWidget {
  const _SaveChip({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final value = fa ? '$percent٪'.localized(context) : '$percent%';
    final green = AppColors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        context.getString.paywall_save(value),
        style: TextStyle(
          color: green,
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          letterSpacing: _labelSpacing(context, 0.6),
        ),
      ),
    );
  }
}

class _Ribbon extends StatelessWidget {
  const _Ribbon({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          colors: [amber, Color.lerp(amber, Colors.deepOrange, 0.35)!],
        ),
        boxShadow: [
          BoxShadow(color: amber.withValues(alpha: 0.35), blurRadius: 10),
        ],
      ),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.background,
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          letterSpacing: _labelSpacing(context, 1),
        ),
      ),
    );
  }
}

/// Pinned under the plans: the one button that buys the selected plan, with
/// its length and price on it, then the reassurance and "restore".
class _CheckoutBar extends StatelessWidget {
  const _CheckoutBar({
    required this.plan,
    required this.busy,
    required this.onBuy,
    required this.onRestore,
    super.key,
  });

  final PlanPricing plan;
  final bool busy;
  final VoidCallback onBuy;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final radius = BorderRadius.circular(18);
    final amber = AppColors.amber;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.card;
    final detail = s.paywall_cta_plan(
      _planLength(context, plan.offer.plan),
      plan.offer.price,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PulseGlow(
            enabled: !busy,
            borderRadius: radius,
            child: PressableScale(
              key: const ValueKey('paywall-buy'),
              onTap: busy ? null : onBuy,
              borderRadius: radius,
              child: AnimatedOpacity(
                duration: duration,
                opacity: busy ? 0.7 : 1,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 60),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 16,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.centerStart,
                      end: AlignmentDirectional.centerEnd,
                      colors: [
                        amber,
                        Color.lerp(amber, Colors.deepOrange, 0.35)!,
                      ],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: AnimatedSwitcher(
                    duration: duration,
                    switchInCurve: AppMotion.easeOut,
                    switchOutCurve: AppMotion.leaving,
                    child: busy
                        ? SizedBox(
                            key: const ValueKey('busy'),
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.6,
                              color: AppColors.background,
                            ),
                          )
                        : Column(
                            key: const ValueKey('label'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                s.paywall_cta,
                                style: TextStyle(
                                  color: AppColors.background,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: _labelSpacing(context, 1.2),
                                ),
                              ),
                              const SizedBox(height: 2),
                              // The plan on the button follows the
                              // selection with a quick crossfade.
                              AnimatedSwitcher(
                                duration: duration,
                                switchInCurve: AppMotion.easeOut,
                                switchOutCurve: AppMotion.leaving,
                                child: Text(
                                  detail,
                                  key: ValueKey(detail),
                                  style: TextStyle(
                                    color: AppColors.background.withValues(
                                      alpha: 0.78,
                                    ),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_rounded,
                size: 13,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  s.paywall_trust,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          Center(
            child: TextButton(
              key: const ValueKey('paywall-restore'),
              onPressed: busy ? null : onRestore,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(
                s.paywall_restore,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.textSecondary.withValues(
                    alpha: 0.4,
                  ),
                  letterSpacing: _labelSpacing(context, 0.6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
