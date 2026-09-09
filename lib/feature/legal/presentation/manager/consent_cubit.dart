import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/utils/logger.dart';
import '../../domain/repository/legal_repository.dart';
import 'consent_state.dart';

/// Decides whether the app may run, and asks when it may not.
///
/// ## The shape of this, and why
///
/// Two separate things happen, and keeping them separate is what makes the
/// behaviour safe:
///
/// 1. **[check]** looks only at what this device already has — the documents
///    bundled in the APK, or a published set already adopted this session —
///    against what it has accepted. It never touches the network, so it
///    always finishes, and it is what the gate waits on at startup.
///
/// 2. **[refreshInBackground]** asks tarkk.ir whether anything newer exists.
///    It is fire-and-forget, it is never awaited by anything the user is
///    waiting for, and when it fails it changes nothing at all.
///
/// A gate only ever appears because of (1). (2) can *cause* (1) to reach a
/// different answer, but only after a complete, verified, newer set has
/// actually been downloaded — so the app is never blocked on the strength of
/// a version number it cannot show the text for.
@injectable
class ConsentCubit extends Cubit<ConsentState> {
  ConsentCubit(this._repository) : super(const ConsentChecking());

  final LegalRepository _repository;

  bool _refreshing = false;

  /// Recomputes from what is already on the device. Offline-safe by
  /// construction, and the only thing that can open the gate.
  Future<void> check() async {
    final sourced = await _repository.currentManifest();
    final pending = <PendingConsent>[];

    for (final ref in sourced.manifest.documents) {
      final accepted = await _repository.acceptedVersion(ref.id);
      if (!ref.requiresAcceptance(accepted)) continue;

      final document = await _repository.document(ref);
      if (document == null) {
        // Unreachable on a correct build: `document()` falls back to the
        // bundled copy. If it ever does happen, the honest response is to
        // let the app run rather than to block on a document nobody can
        // read — a wall with nothing behind it helps no one.
        Logger.diagnostic(
          'Legal: ${ref.id} v${ref.version} needs acceptance but no text is '
          'available; not gating',
        );
        continue;
      }
      pending.add(
        PendingConsent(
          ref: ref,
          document: document,
          previouslyAccepted: accepted,
        ),
      );
    }

    if (isClosed) return;
    emit(pending.isEmpty ? const ConsentSatisfied() : ConsentRequired(pending));
  }

  /// Asks whether anything newer has been published, then re-checks.
  ///
  /// Deliberately returns `void`: no caller may await this, because anything
  /// that awaits a network call has made the app's startup depend on a
  /// connection it is designed not to need. Call it and forget it.
  void refreshInBackground() {
    if (_refreshing) return;
    _refreshing = true;
    unawaited(
      _repository
          .refresh()
          .then((_) async {
            if (isClosed) return;
            // The refresh may have adopted a newer set, in which case this
            // opens the gate. If it failed, refresh() returned what was
            // already in force and this recomputes the same answer.
            await check();
          })
          .catchError((Object e) {
            // refresh() is written not to throw; this is the belt to that
            // brace. An unhandled error here would surface as a crash on a
            // phone with no signal, which is the one thing this feature must
            // never do.
            Logger.log('Legal: background refresh threw — $e');
          })
          .whenComplete(() => _refreshing = false),
    );
  }

  /// Records acceptance of everything currently pending.
  Future<void> accept() async {
    final current = state;
    if (current is! ConsentRequired) return;

    emit(ConsentSaving(current.pending));
    await _repository.recordAcceptance({
      for (final p in current.pending) p.ref.id: p.ref.version,
    });

    if (isClosed) return;
    // Re-checking rather than assuming: if the background refresh landed a
    // newer version between the tap and the write, this catches it instead
    // of letting the app through on an acceptance that is already stale.
    await check();
  }
}
