import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../domain/entity/legal_document.dart';
import '../domain/entity/legal_manifest.dart';

/// The copy of the legal documents that ships inside the APK.
///
/// Written by `scripts/build-legal-pages.mjs` into `assets/legal/`, from the
/// same `website/legal/*.json` the site is rendered from — the same bytes, so
/// a build cannot ship an app whose policy differs from the published one.
///
/// This is the floor the whole feature stands on. Because it is here, consent
/// can be asked for and given on a phone that has never had a connection, and
/// no failure of the network can leave the app unable to show a document it
/// is asking somebody to accept.
/// Registered by `LegalModule` rather than annotated, for the same reason
/// as [HttpApiClient]: the optional bundle is a test seam.
class LegalAssetSource {
  LegalAssetSource({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  static const _dir = 'assets/legal';

  // Read once. The bundle caches strings itself, but parsing 80 KB of JSON on
  // every consent check would be wasteful on the phones this app targets.
  LegalManifest? _manifest;
  final _documents = <String, LegalDocument>{};

  /// The manifest this build shipped with.
  ///
  /// A failure here is a broken build, not a runtime condition — the asset is
  /// generated and verified by `--check` in the same script that writes it —
  /// so it is allowed to throw rather than being papered over. An app that
  /// cannot read its own bundled policy should fail loudly in testing.
  Future<LegalManifest> manifest() async {
    return _manifest ??= LegalManifest.fromJson(
      await _readJson('index.json'),
    );
  }

  Future<LegalDocument> document(String id) async {
    final cached = _documents[id];
    if (cached != null) return cached;
    final doc = LegalDocument.fromJson(await _readJson('$id.json'));
    _documents[id] = doc;
    return doc;
  }

  Future<Map<String, dynamic>> _readJson(String file) async {
    final raw = await _bundle.loadString('$_dir/$file');
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw LegalFormatException('$_dir/$file is not a JSON object');
    }
    return decoded;
  }
}
