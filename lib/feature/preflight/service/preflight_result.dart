import '../../../core/recovery/recovery_check.dart';
import '../domain/service/preflight_checks.dart';

/// A snapshot of every Preflight check, some possibly still in flight.
///
/// Fields are nullable rather than this being a `List<RecoveryCheck>` so the
/// sheet can show a row's known label immediately and let it resolve in
/// place — "results arriving", not a repaint — instead of the whole sheet
/// waiting on the slowest check (the mic probe, ~1.2s) before showing
/// anything. [connection]/[hdVoice]/[diagnostics] are computed synchronously
/// and are non-null from the very first emission; [mic]/[route] (one probe)
/// and [background]/[sharedMusic] resolve shortly after.
class PreflightResult {
  const PreflightResult({
    this.mic,
    this.route,
    this.connection,
    this.background,
    this.hdVoice,
    this.sharedMusic,
    this.diagnostics,
  });

  final RecoveryCheck? mic;
  final RecoveryCheck? route;
  final RecoveryCheck? connection;
  final RecoveryCheck? background;
  final RecoveryCheck? hdVoice;
  final RecoveryCheck? sharedMusic;

  /// Check 8 — computed for the diagnostics log, but not one of the sheet's
  /// six visible rows (see the issue's own suggested UX list, which has no
  /// "Diagnostics" row). [PreflightResult.resolved] still includes it, since
  /// nothing about the blocking-policy gate should differ by row visibility
  /// — it just never renders as its own tile.
  final RecoveryCheck? diagnostics;

  PreflightResult copyWith({
    RecoveryCheck? mic,
    RecoveryCheck? route,
    RecoveryCheck? connection,
    RecoveryCheck? background,
    RecoveryCheck? hdVoice,
    RecoveryCheck? sharedMusic,
    RecoveryCheck? diagnostics,
  }) => PreflightResult(
    mic: mic ?? this.mic,
    route: route ?? this.route,
    connection: connection ?? this.connection,
    background: background ?? this.background,
    hdVoice: hdVoice ?? this.hdVoice,
    sharedMusic: sharedMusic ?? this.sharedMusic,
    diagnostics: diagnostics ?? this.diagnostics,
  );

  /// The sheet's six visible rows, in display order. A null entry means that
  /// check hasn't resolved yet — the sheet renders it as a pending row using
  /// the row's fixed label rather than waiting for it.
  List<RecoveryCheck?> get visibleRows => [
    mic,
    route,
    connection,
    background,
    hdVoice,
    sharedMusic,
  ];

  bool get isComplete => visibleRows.every((c) => c != null) && diagnostics != null;

  /// Every check that has resolved so far — what the blocking-policy gate
  /// reads. Deliberately available before [isComplete]: a hard failure that
  /// resolves early (say, mic permission denied) should disable the CTA the
  /// instant it's known, not wait for the slowest still-pending row.
  List<RecoveryCheck> get resolved =>
      [...visibleRows, diagnostics].whereType<RecoveryCheck>().toList();

  bool get hasBlocking => hasBlockingFailure(resolved);

  bool get hasOnlyWarning => hasOnlyWarnings(resolved);
}
