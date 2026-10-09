import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import 'license_gate.dart';
import 'premium_feature.dart';
import 'subscription_gate_page.dart';
import '../utils/logger.dart';

/// Defers camera/transport construction until access has actually been granted.
/// Cancellation returns to the originating screen without a connection error.
class FeatureAccessGuard extends StatefulWidget {
  const FeatureAccessGuard({
    required this.feature,
    required this.builder,
    required this.onDenied,
    this.onAccessLost,
    this.requestAccess = openSubscriptionGate,
    super.key,
  });

  final PremiumFeature feature;
  final WidgetBuilder builder;
  final VoidCallback onDenied;
  final VoidCallback? onAccessLost;
  final Future<bool> Function(BuildContext, PremiumFeature) requestAccess;

  @override
  State<FeatureAccessGuard> createState() => _FeatureAccessGuardState();
}

class _FeatureAccessGuardState extends State<FeatureAccessGuard> {
  LicenseGate? _gate;
  StreamSubscription<void>? _changes;
  bool _allowed = false;
  bool _requesting = false;

  bool get _hasAccess => _gate?.allows(widget.feature) ?? true;

  @override
  void initState() {
    super.initState();
    final getIt = GetIt.instance;
    _gate = getIt.isRegistered<LicenseGate>() ? getIt<LicenseGate>() : null;
    _allowed = _hasAccess;
    _changes = _gate?.changes.listen((_) {
      if (!mounted) return;
      final allowed = _hasAccess;
      if (_requesting && allowed) return;
      if (_allowed == allowed) return;
      if (!allowed) widget.onAccessLost?.call();
      setState(() => _allowed = allowed);
      if (!allowed) _scheduleRequest();
    });
    if (!_allowed) _scheduleRequest();
  }

  void _scheduleRequest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_allowed && !_requesting) unawaited(_request());
    });
  }

  Future<void> _request() async {
    _requesting = true;
    bool granted;
    try {
      granted = await widget.requestAccess(context, widget.feature);
    } catch (_) {
      Logger.diagnostic('entitlement: access check failed');
      granted = false;
    }
    if (!mounted) return;
    _requesting = false;
    if (granted && _hasAccess) {
      setState(() => _allowed = true);
    } else {
      widget.onDenied();
    }
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _allowed
      ? widget.builder(context)
      : const Scaffold(body: Center(child: CircularProgressIndicator()));
}
