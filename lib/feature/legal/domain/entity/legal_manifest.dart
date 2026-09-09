import 'package:equatable/equatable.dart';

import 'legal_document.dart';

/// What the manifest says about one document, without its text.
///
/// This is the whole point of having a manifest: deciding whether anybody
/// needs to be asked again costs a few hundred bytes rather than the two
/// documents in full. On a phone that is mostly offline and occasionally on a
/// slow connection, that difference is the difference between a check that
/// completes and one that does not.
final class LegalDocumentRef extends Equatable {
  const LegalDocumentRef({
    required this.id,
    required this.name,
    required this.version,
    required this.minAcceptedVersion,
    required this.effectiveDate,
    required this.file,
    required this.webPath,
  });

  factory LegalDocumentRef.fromJson(Map<String, dynamic> json, String where) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw LegalFormatException('$where: missing id');
    }
    final version = json['version'];
    final minAccepted = json['minAcceptedVersion'];
    if (version is! int || version < 1) {
      throw LegalFormatException('$where($id): bad version');
    }
    if (minAccepted is! int || minAccepted < 1 || minAccepted > version) {
      throw LegalFormatException(
        '$where($id): minAcceptedVersion $minAccepted is not within 1..$version',
      );
    }
    final file = json['file'];
    if (file is! String || file.isEmpty) {
      throw LegalFormatException('$where($id): missing file');
    }
    final date = DateTime.tryParse('${json['effectiveDate']}');
    if (date == null) {
      throw LegalFormatException('$where($id): unparseable effectiveDate');
    }
    return LegalDocumentRef(
      id: id,
      name: LocalizedText.fromJson(json['name'], '$where($id).name'),
      version: version,
      minAcceptedVersion: minAccepted,
      effectiveDate: date,
      file: file,
      webPath: LocalizedText.fromJson(json['webPath'], '$where($id).webPath'),
    );
  }

  final String id;
  final LocalizedText name;
  final int version;

  /// The oldest version still counted as accepted — see
  /// [LegalDocument.minAcceptedVersion].
  final int minAcceptedVersion;

  final DateTime effectiveDate;

  /// The document's filename, resolved against wherever the manifest came
  /// from. Relative on purpose: the same manifest is read out of the app
  /// bundle and off the website, and neither should have to rewrite it.
  final String file;

  final LocalizedText webPath;

  /// Whether somebody who accepted [acceptedVersion] has to be asked again.
  ///
  /// `null` means never accepted anything, which is a fresh install.
  bool requiresAcceptance(int? acceptedVersion) =>
      acceptedVersion == null || acceptedVersion < minAcceptedVersion;

  @override
  List<Object?> get props => [id, version, minAcceptedVersion, effectiveDate];
}

/// The published set of legal documents and their current versions.
final class LegalManifest extends Equatable {
  const LegalManifest(this.documents);

  static const supportedSchema = 1;

  factory LegalManifest.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != supportedSchema) {
      throw LegalFormatException(
        'unsupported manifest schema ${json['schema']} '
        '(this build reads $supportedSchema)',
      );
    }
    final docs = json['documents'];
    if (docs is! List || docs.isEmpty) {
      throw const LegalFormatException('manifest lists no documents');
    }
    return LegalManifest(
      docs.indexed
          .map(
            (e) => LegalDocumentRef.fromJson(
              e.$2 as Map<String, dynamic>,
              'documents[${e.$1}]',
            ),
          )
          .toList(growable: false),
    );
  }

  final List<LegalDocumentRef> documents;

  LegalDocumentRef? byId(String id) {
    for (final doc in documents) {
      if (doc.id == id) return doc;
    }
    return null;
  }

  @override
  List<Object?> get props => [documents];
}
