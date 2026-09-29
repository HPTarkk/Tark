import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_session.dart';
import '../config/support_config.dart';
import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../router/routes.dart';
import '../theme/app_colors.dart';
import '../utils/friendly_date.dart';
import '../utils/logger.dart';
import 'billing_service.dart';
import 'license_gate.dart';
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
  const SubscriptionGatePage({required this.feature, super.key});

  final PremiumFeature feature;

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

  _View _view = const _Checking();
  List<BillingPlanOffer> _offers = const [];
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
      _offers = await _billing.offers();
      if (!mounted) return;
    }
    setState(() => _view = _Resolved(outcome));
    if (outcome is GateGranted) {
      await Future<void>.delayed(AppMotion.confirmHold ~/ 2);
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  Future<void> _purchase(BillingPlan plan) async {
    setState(() => _busy = true);
    final result = await _billing.purchase(plan);
    if (!mounted) return;
    switch (result) {
      case PurchaseSuccess(:final purchase):
        setState(() => _view = const _Checking());
        final outcome = await _subscription.submitBazaarPurchase(
          sku: purchase.plan.sku,
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
        sku: purchase.plan.sku,
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
      SnackBar(content: Text(message), backgroundColor: AppColors.card),
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: Icon(Icons.close_rounded, color: AppColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
            Expanded(
              child: PhaseSwitcher(
                alignment: Alignment.center,
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
            ),
          ],
        ),
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
        offers: _offers,
        busy: _busy,
        onPurchase: _purchase,
        onRestore: _restore,
      ),
      GateSignInRequired() => _MessageState(
        icon: Icons.account_circle_outlined,
        title: s.sub_signin_title,
        body: s.sub_signin_body,
        action: _canSignIn ? s.sub_signin_action : null,
        onAction: _signIn,
      ),
      GatePurchaseOwnedElsewhere() => _MessageState(
        icon: Icons.swap_horiz_rounded,
        title: s.sub_owned_title,
        body: s.sub_owned_body,
        showSupport: true,
      ),
    };
  }
}

/// A calm, breathing mark while the one request is in flight — not a bar
/// that implies a known amount of remaining work.
class _CheckingState extends StatelessWidget {
  const _CheckingState({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PulseGlow(
          borderRadius: BorderRadius.circular(48),
          child: _Glyph(icon: Icons.sync_rounded, spinning: true),
        ),
        const SizedBox(height: 22),
        Text(
          context.getString.sub_checking,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
      ],
    );
  }
}

class _GrantedState extends StatelessWidget {
  const _GrantedState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1),
          duration: AppMotion.entrance,
          curve: Curves.elasticOut,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: _Glyph(icon: Icons.check_rounded, color: AppColors.green),
        ),
        const SizedBox(height: 22),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
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

    final (icon, title, body) = switch (outcome.reason) {
      CheckReason.noData => (
        Icons.cloud_sync_rounded,
        s.sub_nodata_title,
        trouble ? s.sub_nodata_body_trouble : s.sub_nodata_body_offline,
      ),
      CheckReason.expired => (
        Icons.event_repeat_rounded,
        s.sub_expired_title,
        trouble
            ? s.sub_expired_body_trouble(date(outcome.endedAt))
            : s.sub_expired_body_offline(date(outcome.endedAt)),
      ),
      CheckReason.staleCheck => (
        Icons.wifi_tethering_rounded,
        s.sub_stale_title,
        trouble
            ? s.sub_stale_body_trouble(date(outcome.lastCheckedAt))
            : s.sub_stale_body_offline(date(outcome.lastCheckedAt)),
      ),
    };

    return _StateLayout(
      glyph: _Glyph(icon: icon),
      title: title,
      body: body,
      footer: [
        _PrimaryButton(label: s.sub_try_again, onTap: onRetry, glow: true),
        const SizedBox(height: 18),
        const _SupportCard(),
        const SizedBox(height: 14),
        _FreeNote(text: s.sub_free_meanwhile),
      ],
    );
  }
}

class _SubscribeState extends StatelessWidget {
  const _SubscribeState({
    required this.feature,
    required this.endedAt,
    required this.offers,
    required this.busy,
    required this.onPurchase,
    required this.onRestore,
  });

  final PremiumFeature feature;
  final DateTime? endedAt;
  final List<BillingPlanOffer> offers;
  final bool busy;
  final ValueChanged<BillingPlan> onPurchase;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final ended = endedAt;
    final reason = switch (feature) {
      PremiumFeature.wifiTransport => s.paywall_locked_wifi,
      PremiumFeature.selfMute => s.paywall_locked_mute,
      PremiumFeature.musicPlayback => s.paywall_locked_music,
    };

    return _StateLayout(
      glyph: _Glyph(icon: Icons.workspace_premium_rounded),
      title: ended == null ? s.paywall_title : s.sub_renew_title,
      body: ended == null
          ? reason
          : s.sub_renew_body(FriendlyDate.format(context, ended)),
      footer: [
        for (final plan in BillingPlan.values) ...[
          _PlanRow(
            label: switch (plan) {
              BillingPlan.monthly => s.paywall_plan_1m,
              BillingPlan.yearly => s.paywall_plan_12m,
            },
            price: _priceFor(plan),
            onTap: offers.isEmpty || busy ? null : () => onPurchase(plan),
          ),
          const SizedBox(height: 8),
        ],
        if (offers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.paywall_unavailable,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary.withAlpha(180),
                fontSize: 11,
              ),
            ),
          ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: busy || offers.isEmpty ? null : onRestore,
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
        _FreeNote(text: s.paywall_free_note),
      ],
    );
  }

  String? _priceFor(BillingPlan plan) {
    for (final offer in offers) {
      if (offer.plan == plan) return offer.price;
    }
    return null;
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.body,
    this.showSupport = false,
    this.action,
    this.onAction,
  });

  final IconData icon;
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
      glyph: _Glyph(icon: icon),
      title: title,
      body: body,
      footer: [
        if (label != null && onTap != null) ...[
          _PrimaryButton(label: label, onTap: onTap, glow: true),
          const SizedBox(height: 18),
        ],
        if (showSupport) const _SupportCard(),
        const SizedBox(height: 14),
        _FreeNote(text: context.getString.sub_free_meanwhile),
      ],
    );
  }
}

/// Shared skeleton for every resolved state: glyph, heading, body, then the
/// state's own actions — arriving in the app's usual stagger.
class _StateLayout extends StatelessWidget {
  const _StateLayout({
    required this.glyph,
    required this.title,
    required this.body,
    required this.footer,
  });

  final Widget glyph;
  final String title;
  final String body;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: StaggeredEntrance(
        builder: (context, items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: items,
        ),
        children: [
          Center(child: glyph),
          Padding(
            padding: const EdgeInsets.only(top: 24),
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
            padding: const EdgeInsets.only(top: 12, bottom: 28),
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
      ),
    );
  }
}

class _Glyph extends StatefulWidget {
  const _Glyph({required this.icon, this.color, this.spinning = false});

  final IconData icon;
  final Color? color;
  final bool spinning;

  @override
  State<_Glyph> createState() => _GlyphState();
}

class _GlyphState extends State<_Glyph> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.spinning) _spin.loopUnlessReduced(context);
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.amber;
    final icon = Icon(widget.icon, size: 40, color: color);
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      alignment: Alignment.center,
      child: widget.spinning
          ? RotationTransition(turns: _spin, child: icon)
          : icon,
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
    final radius = BorderRadius.circular(14);
    return PulseGlow(
      enabled: glow,
      borderRadius: radius,
      child: PressableScale(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.amber,
            borderRadius: radius,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.background,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.sub_support_prompt,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () =>
                launchUrl(SupportConfig.mailto(subject: s.sub_email_subject)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.mail_outline_rounded,
                    size: 18,
                    color: AppColors.amber,
                  ),
                  const SizedBox(width: 8),
                  // An address is an identifier: always left-to-right, even
                  // inside a Persian layout.
                  Flexible(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        SupportConfig.email,
                        style: TextStyle(
                          color: AppColors.amber,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.amber.withAlpha(120),
                        ),
                      ),
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

class _FreeNote extends StatelessWidget {
  const _FreeNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.bluetooth_rounded, color: AppColors.textSecondary, size: 14),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
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
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: enabled ? AppColors.amber.withAlpha(90) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: enabled
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 13,
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
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
