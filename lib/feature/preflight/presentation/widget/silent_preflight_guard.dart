import 'package:flutter/widgets.dart';

import '../../../../core/l10n/extension.dart';
import '../../../transfer/domain/entity/transfer_mode.dart';
import '../../../transfer/domain/service/transport_advisor.dart';
import '../../domain/service/pinned_plan.dart';
import '../../service/preflight_result.dart';
import '../../service/preflight_service.dart';
import '../page/preflight_page.dart';

/// Runs Preflight silently for a quick-access ("goLive") destination page,
/// per the product decision behind #33: the home-widget shortcut exists to
/// be instant, so it must not gain the full page's beat of friction. Checks
/// still run — they only ever interrupt on a hard failure, never a warning.
///
/// **Only mix this into a page that does not yet own the real
/// `AudioEngine`/`WalkieTalkieCubit`** — `MicProbe`'s throwaway engine would
/// otherwise contend with the real one for the microphone at the same
/// moment. That is exactly why `WalkieTalkiePage` (the direct-Wi-Fi
/// quick-access destination) does **not** use this guard: it owns the real
/// engine from the instant it mounts, and its existing troubleshooting
/// sheet/banner (`channel_recovery.dart`) already surfaces a denied/silent
/// mic once inside — duplicating that here would be the second probe this
/// mixin exists to prevent. `BluetoothConnectPage`/`WifiHotspotPage`/
/// `GuestLinkPage` are pre-channel setup/pairing screens with no engine yet,
/// which is what makes the guard safe there.
mixin SilentPreflightGuard<T extends StatefulWidget> on State<T> {
  /// The transport this page is already running under.
  TransferMode get preflightMode;

  /// Test seam: a page's `State` (or a test double standing in for one) can
  /// override this to substitute a fake session, the same way
  /// `showPreflightPage`'s own `startSession` parameter does.
  @protected
  PreflightSessionStarter get preflightStarter => PreflightService.start;

  PreflightSession? _guardSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSilently());
  }

  @override
  void dispose() {
    _guardSession?.dispose();
    super.dispose();
  }

  Future<void> _runSilently() async {
    if (!mounted) return;
    final plan = await pinnedPlanFor(preflightMode);
    if (!mounted) return;
    final session = preflightStarter(s: context.getString, plan: plan);
    _guardSession = session;

    if (session.initial.isComplete) {
      await _reactTo(session.initial, plan);
      return;
    }
    await for (final result in session.results) {
      if (!mounted) return;
      if (result.isComplete) {
        await _reactTo(result, plan);
        return;
      }
    }
  }

  Future<void> _reactTo(PreflightResult result, ChannelPlan plan) async {
    if (!mounted || !result.hasBlocking) return;
    // The same full page as the normal flow — familiar UI, and its own CTA
    // gating is what actually resolves the failure; this guard's only job is
    // deciding *whether* to show it. Same starter as above (not just the
    // same function): a test double substituted via [preflightStarter] must
    // govern the forced page too, or a test can prove the silent check but
    // not what it triggers.
    await showPreflightPage(context, plan: plan, startSession: preflightStarter);
  }
}
