import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import '../domain/entity/legal_document.dart';
import '../domain/entity/legal_manifest.dart';
import '../domain/repository/legal_repository.dart';
import 'legal_asset_source.dart';
import 'legal_remote_source.dart';

/// Keys owned by this feature. Permanent once shipped, like every other
/// preference key in the app.
abstract final class LegalKeys {
  /// `legal_accepted_<documentId>` → the integer version accepted.
  ///
  /// One key per document rather than one blob, so a document added later
  /// starts from "never accepted" without any migration.
  static String accepted(String documentId) => 'legal_accepted_$documentId';
}

/// [LegalRepository] over the bundled assets, the published files, and
/// SharedPreferences.
///
/// ## Why nothing downloaded is written to disk
///
/// A newer manifest is held **in memory for the session only**, and only once
/// every document it names has also been downloaded and parsed. That is a
/// deliberate choice, and it is what makes the promise in [LegalRepository]
/// structurally true rather than merely intended.
///
/// The alternative — persisting "v2 exists" and fetching the text when the
/// gate opens — creates a state this app must never be able to reach: knowing
/// it has to block, while being unable to show what it is blocking on. A
/// phone that was briefly online at 9am and is in a tunnel at 9:05 would be
/// left holding a modal it cannot fill. Keeping the knowledge and the text
/// together, and keeping both out of storage, makes that state unreachable
/// instead of merely unlikely.
///
/// What it costs: somebody who force-quits the gate and never has a
/// connection again is not asked. That is the right side to err on for an app
/// whose whole purpose is working with no connection.
@LazySingleton(as: LegalRepository)
class LegalRepositoryImpl implements LegalRepository {
  LegalRepositoryImpl(this._assets, this._remote, this._prefs);

  final LegalAssetSource _assets;
  final LegalRemoteSource _remote;
  final SharedPreferences _prefs;

  /// A complete, self-consistent published set: a manifest plus every
  /// document it names. Replaced only as a whole, never patched.
  ({LegalManifest manifest, Map<String, LegalDocument> documents})? _fetched;

  @override
  Future<SourcedManifest> currentManifest() async {
    final fetched = _fetched;
    if (fetched != null) {
      return SourcedManifest(fetched.manifest, LegalSource.remote);
    }
    return SourcedManifest(await _assets.manifest(), LegalSource.bundled);
  }

  @override
  Future<LegalDocument?> document(LegalDocumentRef ref) async {
    final downloaded = _fetched?.documents[ref.id];
    if (downloaded != null && downloaded.version == ref.version) {
      return downloaded;
    }
    try {
      return await _assets.document(ref.id);
    } catch (e) {
      // Only reachable on a broken build, or on a ref for a document this
      // APK predates. Neither is worth crashing a running app over.
      Logger.log('Legal: no bundled copy of ${ref.id} — $e');
      return null;
    }
  }

  @override
  Future<SourcedManifest> refresh() async {
    final bundled = await _assets.manifest();

    final published = await _remote.manifest();
    if (published == null) return await currentManifest();

    // Nothing published is newer than what shipped: the common case, and it
    // costs one small request. Keep the bundled set so `document()` reads
    // assets rather than holding a duplicate in memory.
    final newer = published.documents
        .where((ref) => _isNewerThanBundled(ref, bundled))
        .toList(growable: false);
    if (newer.isEmpty) {
      _fetched = null;
      return SourcedManifest(bundled, LegalSource.bundled);
    }

    // Something is newer, so the text has to come with it. All of it, or
    // none — a half-downloaded set is the state this class exists to avoid.
    final documents = <String, LegalDocument>{};
    for (final ref in newer) {
      final doc = await _remote.document(ref);
      if (doc == null) {
        Logger.log(
          'Legal: ${ref.id} v${ref.version} is published but could not be '
          'fetched — keeping the bundled set',
        );
        return await currentManifest();
      }
      documents[ref.id] = doc;
    }

    Logger.log(
      'Legal: published set adopted — '
      '${newer.map((r) => '${r.id} v${r.version}').join(', ')}',
    );
    _fetched = (manifest: published, documents: documents);
    return SourcedManifest(published, LegalSource.remote);
  }

  bool _isNewerThanBundled(LegalDocumentRef ref, LegalManifest bundled) {
    final local = bundled.byId(ref.id);
    // A document the bundle has never heard of is newer by definition.
    return local == null || ref.version > local.version;
  }

  @override
  Future<int?> acceptedVersion(String documentId) async {
    return _prefs.getInt(LegalKeys.accepted(documentId));
  }

  @override
  Future<void> recordAcceptance(Map<String, int> versionsById) async {
    for (final entry in versionsById.entries) {
      await _prefs.setInt(LegalKeys.accepted(entry.key), entry.value);
    }
    Logger.log(
      'Legal: accepted ${versionsById.entries.map((e) => '${e.key} v${e.value}').join(', ')}',
    );
  }
}
