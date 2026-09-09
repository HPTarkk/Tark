import 'package:equatable/equatable.dart';

import '../../domain/entity/legal_document.dart';
import '../../domain/entity/legal_manifest.dart';

/// One document the reader is being asked to accept, with its text already in
/// hand.
///
/// The pairing is the point: the gate is never built from a version number
/// alone, so there is no way to reach a screen that must block on something
/// it cannot display.
final class PendingConsent extends Equatable {
  const PendingConsent({
    required this.ref,
    required this.document,
    required this.previouslyAccepted,
  });

  final LegalDocumentRef ref;
  final LegalDocument document;

  /// The version this device accepted before, or `null` on a first run.
  /// What separates "here is what changed" from "here is what this is".
  final int? previouslyAccepted;

  bool get isFirstTime => previouslyAccepted == null;

  @override
  List<Object?> get props => [ref, document, previouslyAccepted];
}

sealed class ConsentState extends Equatable {
  const ConsentState();

  @override
  List<Object?> get props => [];
}

/// Before the first check has finished — a few milliseconds of reading two
/// bundled assets, with no network involved.
final class ConsentChecking extends ConsentState {
  const ConsentChecking();
}

/// Everything published has been accepted. The app is free to run.
final class ConsentSatisfied extends ConsentState {
  const ConsentSatisfied();
}

/// One or more documents need accepting before the app may be used.
final class ConsentRequired extends ConsentState {
  const ConsentRequired(this.pending);

  final List<PendingConsent> pending;

  /// True when this is a fresh install rather than an update to something
  /// already accepted. The screen says a different thing in each case.
  bool get isFirstRun => pending.every((p) => p.isFirstTime);

  @override
  List<Object?> get props => [pending];
}

/// The reader accepted, and the acceptance is being written.
///
/// Distinct from [ConsentSatisfied] so the button can show progress without
/// the gate flickering out from under the finger that pressed it.
final class ConsentSaving extends ConsentState {
  const ConsentSaving(this.pending);

  final List<PendingConsent> pending;

  @override
  List<Object?> get props => [pending];
}
