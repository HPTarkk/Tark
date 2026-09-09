import 'package:injectable/injectable.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/logger.dart';
import '../domain/entity/legal_document.dart';
import '../domain/entity/legal_manifest.dart';

/// Fetches the published legal documents from tarkk.ir.
///
/// Every method answers with `null` rather than an error. That is not
/// swallowing failures — they are logged — it is the shape the one caller
/// wants: [LegalRepositoryImpl] has exactly the same thing to do whether the
/// phone is in a tunnel, the host is down, or somebody published a typo into
/// the JSON, which is *carry on with what it already had*.
@lazySingleton
class LegalRemoteSource {
  LegalRemoteSource(this._api);

  final ApiClient _api;

  /// Overridable per build, so a fork pointing at its own site does not have
  /// to patch code:
  ///
  ///     flutter build apk --dart-define=TARK_LEGAL_BASE=https://example.com/legal/
  ///
  /// A trailing slash is required; the manifest and each document resolve
  /// against it.
  static const base = String.fromEnvironment(
    'TARK_LEGAL_BASE',
    defaultValue: 'https://tarkk.ir/legal/',
  );

  /// Whether this build has anywhere to ask. An empty base compiles the
  /// check out entirely, the way an empty ADTRACE_TOKEN does for analytics.
  static bool get isConfigured => base.isNotEmpty;

  Future<LegalManifest?> manifest() async {
    final json = await _get('index.json');
    if (json == null) return null;
    try {
      return LegalManifest.fromJson(json);
    } on LegalFormatException catch (e) {
      // The published file is static and hand-edited upstream of a build
      // script; it can be wrong. Refusing it here is what stops a malformed
      // manifest from being treated as "a new version exists".
      Logger.log('Legal: published manifest rejected — ${e.message}');
      return null;
    }
  }

  Future<LegalDocument?> document(LegalDocumentRef ref) async {
    final json = await _get(ref.file);
    if (json == null) return null;
    try {
      final doc = LegalDocument.fromJson(json);
      if (doc.id != ref.id || doc.version != ref.version) {
        // The manifest and the document have to agree. If they do not, one
        // of them is stale on the server and neither can be trusted to say
        // what the reader is being asked to accept.
        Logger.log(
          'Legal: ${ref.file} is ${doc.id} v${doc.version}, '
          'manifest says ${ref.id} v${ref.version} — discarding',
        );
        return null;
      }
      return doc;
    } on LegalFormatException catch (e) {
      Logger.log('Legal: ${ref.file} rejected — ${e.message}');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _get(String file) async {
    if (!isConfigured) return null;
    final url = Uri.tryParse('$base$file');
    if (url == null) {
      Logger.log('Legal: TARK_LEGAL_BASE + $file is not a URL');
      return null;
    }
    final result = await _api.getJson(url);
    return result.fold((failure) {
      Logger.log('Legal: $file — ${failure.message}');
      return null;
    }, (json) => json);
  }
}
