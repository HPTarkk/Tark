import '../entity/legal_document.dart';
import '../entity/legal_manifest.dart';

/// Where a manifest or a document came from.
///
/// Worth carrying, because it is the difference between "these are the
/// versions this build shipped with" and "these are the versions that are
/// actually published right now" — and only the second one may ever cause
/// somebody to be interrupted.
enum LegalSource {
  /// Read out of `assets/legal/`, written at build time by
  /// `scripts/build-legal-pages.mjs`. Always available, never newer than the
  /// APK.
  bundled,

  /// Fetched from tarkk.ir and cached on this device.
  remote,
}

/// A manifest together with where it came from.
final class SourcedManifest {
  const SourcedManifest(this.manifest, this.source);
  final LegalManifest manifest;
  final LegalSource source;
}

/// The published legal documents, and what this device has accepted.
///
/// ## The rule this whole feature is built around
///
/// **Nothing here may ever stop the app working because a request failed.**
/// Tark is for talking to people when there is no internet; an app that
/// refuses to open a channel because it could not reach a web server would
/// be broken in exactly the situation it exists for. So:
///
/// * The bundled copy is the floor. Consent can always be *asked for* and
///   *given* with no connectivity at all, using the documents in the APK.
/// * The network is only ever allowed to reveal that something **newer**
///   exists. A failed, slow or absent refresh leaves the app exactly as it
///   was.
/// * A refresh that returns something malformed is discarded, not applied.
///   The published file is static and could be published wrong.
abstract interface class LegalRepository {
  /// The newest manifest this device knows about: the cached remote one if a
  /// refresh has ever succeeded and is still parseable, otherwise the copy
  /// bundled with the app.
  ///
  /// Never fails, and never touches the network.
  Future<SourcedManifest> currentManifest();

  /// One document in full, for showing to the reader.
  ///
  /// Prefers the cached remote copy when its version matches [ref], and falls
  /// back to the bundled one otherwise — including when a download succeeded
  /// for the manifest but not for the document itself, which is exactly the
  /// case where showing the older text beats showing none.
  ///
  /// Returns `null` only when neither copy can be read, which on a correctly
  /// built APK cannot happen.
  Future<LegalDocument?> document(LegalDocumentRef ref);

  /// Asks tarkk.ir whether anything newer has been published, and caches it
  /// if so.
  ///
  /// Returns the manifest now in force — which is the previous one when the
  /// check failed, was refused, or came back malformed. Deliberately does not
  /// report *why* it failed: no caller has anything useful to do with that,
  /// and every one of them behaves identically either way. The reason goes to
  /// the diagnostic log.
  Future<SourcedManifest> refresh();

  /// The version of [documentId] this device has accepted, if any.
  Future<int?> acceptedVersion(String documentId);

  /// Records that the reader accepted these documents at these versions.
  ///
  /// Written together: accepting the terms without the privacy policy is not
  /// a state this app has a screen for, and a half-written acceptance would
  /// re-prompt forever.
  Future<void> recordAcceptance(Map<String, int> versionsById);
}
