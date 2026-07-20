import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';

/// Telegram-desktop-style dynamic connection bar for [ConnectionHealth].
///
///  * **reconnecting, scheduled** — amber bar counting down to the next
///    attempt ("Reconnecting in Ns") with a draining progress bar. The delay
///    grows each failed try (the transport's exponential backoff) and resets
///    on a successful reconnect, so the countdown visibly lengthens the longer
///    the link stays down — exactly Telegram's behaviour.
///  * **reconnecting, attempting** — amber bar with an indeterminate sweeping
///    line (no schedule to count down to, e.g. mid-rebind or Bluetooth/Guest).
///  * Either reconnecting state offers a live **"Reconnect now"** that cuts the
///    backoff short (WifiTransferRepositoryImpl.retryNow, made interruptible).
///  * **down** — red bar with a manual retry (auto-reconnect off / exhausted).
///  * **healthy** — flashes a green "Connected" on RECOVERY, then collapses.
class ConnectionHealthBanner extends StatefulWidget {
  const ConnectionHealthBanner({
    super.key,
    required this.health,
    required this.transferMode,
    required this.onRetry,
  });

  final ConnectionHealth health;
  final TransferMode transferMode;
  final VoidCallback onRetry;

  @override
  State<ConnectionHealthBanner> createState() => _ConnectionHealthBannerState();
}

enum _Display { hidden, countdown, attempting, down, connected }

class _ConnectionHealthBannerState extends State<ConnectionHealthBanner>
    with SingleTickerProviderStateMixin {
  // How long the green "Connected" confirmation lingers before collapsing.
  static const _connectedFlash = Duration(milliseconds: 1400);
  static const _tick = Duration(milliseconds: 200);

  late _Display _display = _computeDisplay(wasHealthy: true);
  Timer? _flashTimer;
  Timer? _countdownTimer;

  // Slow, continuous rotation of the reconnecting icon. Cheap — only shown
  // while the bar is up.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _syncCountdownTimer();
  }

  @override
  void didUpdateWidget(ConnectionHealthBanner old) {
    super.didUpdateWidget(old);
    if (old.health == widget.health) return;
    _flashTimer?.cancel();
    setState(() {
      _display = _computeDisplay(wasHealthy: old.health.isHealthy);
    });
    if (_display == _Display.connected) {
      _flashTimer = Timer(_connectedFlash, () {
        if (mounted) setState(() => _display = _Display.hidden);
      });
    }
    _syncCountdownTimer();
  }

  _Display _computeDisplay({required bool wasHealthy}) {
    final h = widget.health;
    switch (h.status) {
      case ConnectionHealthStatus.reconnecting:
        final at = h.nextRetryAt;
        return (at != null && at.isAfter(DateTime.now()))
            ? _Display.countdown
            : _Display.attempting;
      case ConnectionHealthStatus.down:
        return _Display.down;
      case ConnectionHealthStatus.healthy:
        // Only celebrate an actual recovery, not a channel that opened healthy.
        return wasHealthy ? _Display.hidden : _Display.connected;
    }
  }

  // Ticks the on-screen countdown while one is scheduled; when the wait
  // elapses we fall back to the indeterminate "attempting" look until the
  // transport reports the next state.
  void _syncCountdownTimer() {
    if (_display == _Display.countdown) {
      _countdownTimer ??= Timer.periodic(_tick, (_) {
        final at = widget.health.nextRetryAt;
        if (at == null || !at.isAfter(DateTime.now())) {
          _countdownTimer?.cancel();
          _countdownTimer = null;
          if (mounted) setState(() => _display = _Display.attempting);
        } else if (mounted) {
          setState(() {});
        }
      });
    } else {
      _countdownTimer?.cancel();
      _countdownTimer = null;
    }
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _countdownTimer?.cancel();
    _spin.dispose();
    super.dispose();
  }

  Color get _accent => switch (_display) {
    _Display.down => AppColors.red,
    _Display.connected => AppColors.green,
    _ => AppColors.amber,
  };

  Duration get _remaining {
    final at = widget.health.nextRetryAt;
    if (at == null) return Duration.zero;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _display == _Display.hidden
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _bar(s),
            ),
    );
  }

  Widget _bar(AppLocalizations s) {
    final accent = _accent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      width: double.infinity,
      decoration: BoxDecoration(
        color: accent.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(130)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // Stretch so the full-width progress line gets tight width constraints
        // (a center-aligned column would collapse it to zero width).
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                _leadingIcon(accent),
                const SizedBox(width: 10),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      _message(s),
                      // Key on the label so only real text changes cross-fade,
                      // not every per-second countdown tick.
                      key: ValueKey(_message(s)),
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (_display != _Display.connected)
                  TextButton(
                    onPressed: widget.onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: accent,
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
          _progressLine(accent),
        ],
      ),
    );
  }

  Widget _progressLine(Color accent) {
    switch (_display) {
      case _Display.countdown:
        final total = widget.health.retryDelay?.inMilliseconds ?? 0;
        final fraction = total <= 0
            ? 0.0
            : (_remaining.inMilliseconds / total).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: _DepletingLine(color: accent, fraction: fraction),
        );
      case _Display.attempting:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: _SweepLine(color: accent),
        );
      case _Display.down:
      case _Display.connected:
      case _Display.hidden:
        return const SizedBox.shrink();
    }
  }

  Widget _leadingIcon(Color accent) {
    switch (_display) {
      case _Display.countdown:
      case _Display.attempting:
        return RotationTransition(
          turns: _spin,
          child: Icon(Icons.sync_rounded, size: 16, color: accent),
        );
      case _Display.down:
        return Icon(Icons.wifi_off_rounded, size: 16, color: accent);
      case _Display.connected:
        return Icon(Icons.check_circle_rounded, size: 16, color: accent);
      case _Display.hidden:
        return const SizedBox.shrink();
    }
  }

  String _message(AppLocalizations s) {
    final isBluetooth = widget.transferMode == TransferMode.bluetooth;
    switch (_display) {
      case _Display.countdown:
        final seconds = (_remaining.inMilliseconds / 1000).ceil();
        return s.link_reconnecting_in(seconds);
      case _Display.attempting:
        return isBluetooth ? s.bt_link_reconnecting : s.link_reconnecting;
      case _Display.down:
        return isBluetooth ? s.bt_link_down : s.link_down;
      case _Display.connected:
      case _Display.hidden:
        return s.bt_connected;
    }
  }
}

/// A thin bar that shrinks left as [fraction] falls 1→0 — the countdown timer
/// draining toward the next reconnect attempt.
class _DepletingLine extends StatelessWidget {
  const _DepletingLine({required this.color, required this.fraction});

  final Color color;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 2.5,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: color.withAlpha(28))),
            // 100ms ease smooths the ~200ms tick steps into a continuous drain.
            Align(
              alignment: Alignment.centerLeft,
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 100),
                widthFactor: fraction,
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin indeterminate progress line whose bright segment sweeps across the
/// track forever — the "attempting now" motion (no fixed schedule to drain).
class _SweepLine extends StatefulWidget {
  const _SweepLine({required this.color});

  final Color color;

  @override
  State<_SweepLine> createState() => _SweepLineState();
}

class _SweepLineState extends State<_SweepLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 2.5,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: widget.color.withAlpha(28)),
            ),
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                // Ease the sweep and carry the segment fully off both edges so
                // it fades in/out at the ends instead of hard-stopping.
                final t = Curves.easeInOut.transform(_c.value);
                return Align(
                  alignment: Alignment(-1.5 + t * 3.0, 0),
                  child: FractionallySizedBox(
                    widthFactor: 0.32,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            widget.color.withAlpha(0),
                            widget.color,
                            widget.color.withAlpha(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
