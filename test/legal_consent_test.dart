import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/legal/data/legal_repository_impl.dart';
import 'package:tark/feature/legal/domain/entity/legal_document.dart';
import 'package:tark/feature/legal/domain/entity/legal_manifest.dart';
import 'package:tark/feature/legal/domain/repository/legal_repository.dart';
import 'package:tark/feature/legal/presentation/manager/consent_cubit.dart';
import 'package:tark/feature/legal/presentation/manager/consent_state.dart';

/// The rules this feature promises, as tests.
///
/// Every one of these is a rule the app would still *appear* to satisfy if it
/// were broken — a gate that never opens looks the same as one with nothing
/// to ask, and an app that blocks on a failed request looks like an app with
/// no signal. So they are pinned here rather than left to a manual check.
void main() {
  // ── Fixtures ───────────────────────────────────────────────────────

  Map<String, dynamic> documentJson({
    required String id,
    required int version,
    int? minAccepted,
    String? extraBlockType,
  }) => {
    'schema': 1,
    'id': id,
    'name': {'en': id, 'fa': id},
    'version': version,
    'minAcceptedVersion': minAccepted ?? version,
    'effectiveDate': '2026-09-08',
    'effectiveDateLabel': {'en': '8 September 2026', 'fa': '۱۷ شهریور ۱۴۰۵'},
    'webPath': {'en': '/$id.html', 'fa': '/fa/$id.html'},
    'meta': const <String, dynamic>{},
    'hero': {
      'heading': {'en': 'Heading', 'fa': 'عنوان'},
      'lede': {'en': 'Lede', 'fa': 'مقدمه'},
    },
    'summary': {
      'columns': [
        {
          'kind': 'asks',
          'title': {'en': 'What leaves', 'fa': 'چی می‌ره'},
          'items': [
            {'en': 'Very little', 'fa': 'خیلی کم'},
          ],
        },
      ],
    },
    'sections': [
      {
        'id': 'one',
        'title': {'en': 'Section one', 'fa': 'بخش یک'},
        'blocks': [
          {
            'type': 'p',
            'text': {'en': 'Body text.', 'fa': 'متن.'},
          },
          if (extraBlockType != null) {'type': extraBlockType},
        ],
      },
    ],
  };

  Map<String, dynamic> manifestJson(List<Map<String, dynamic>> docs) => {
    'schema': 1,
    'documents': [
      for (final d in docs)
        {
          'id': d['id'],
          'name': d['name'],
          'version': d['version'],
          'minAcceptedVersion': d['minAcceptedVersion'],
          'effectiveDate': d['effectiveDate'],
          'file': '${d['id']}.json',
          'webPath': d['webPath'],
        },
    ],
  };

  // ── Doubles ────────────────────────────────────────────────────────

  /// Stands in for both the bundled assets and the published files, so a
  /// test can say "the APK has v1, the website has v2" in one place.
  late Map<String, Map<String, dynamic>> bundled;
  late Map<String, Map<String, dynamic>>? published;
  late int documentFetches;
  late Set<String> unfetchableDocuments;

  setUp(() {
    final v1 = documentJson(id: 'privacy', version: 1);
    bundled = {'privacy': v1, 'index': manifestJson([v1])};
    published = null;
    documentFetches = 0;
    unfetchableDocuments = {};
    SharedPreferences.setMockInitialValues({});
  });

  Future<LegalRepository> buildRepository() async {
    final prefs = await SharedPreferences.getInstance();
    return _FakeBackedRepository(
      readBundled: (name) => bundled[name],
      readPublished: (name) {
        if (published == null) return null;
        if (name != 'index') {
          documentFetches += 1;
          if (unfetchableDocuments.contains(name)) return null;
        }
        return published![name];
      },
      prefs: prefs,
    );
  }

  // ── The gate opens when it should ──────────────────────────────────

  test('a fresh install has to accept what the APK shipped with', () async {
    final cubit = ConsentCubit(await buildRepository());
    await cubit.check();

    final state = cubit.state;
    expect(state, isA<ConsentRequired>());
    state as ConsentRequired;
    expect(state.isFirstRun, isTrue);
    expect(state.pending.single.ref.id, 'privacy');
    // The text is in hand, not merely referenced — this is the invariant
    // that makes "block on something we cannot display" unreachable.
    expect(state.pending.single.document.version, 1);
  });

  test('accepting lets the app through, and stays accepted', () async {
    final repository = await buildRepository();
    final cubit = ConsentCubit(repository);

    await cubit.check();
    await cubit.accept();
    expect(cubit.state, isA<ConsentSatisfied>());

    // A second launch does not ask again.
    final second = ConsentCubit(repository);
    await second.check();
    expect(second.state, isA<ConsentSatisfied>());
  });

  // ── The gate stays shut when it should ─────────────────────────────

  test(
    'a failed refresh never blocks the app, and never changes anything',
    () async {
      final repository = await buildRepository();
      final cubit = ConsentCubit(repository);
      await cubit.check();
      await cubit.accept();
      expect(cubit.state, isA<ConsentSatisfied>());

      // `published` stays null: every request fails, the way it does on a
      // phone with no signal.
      cubit.refreshInBackground();
      await Future<void>.delayed(Duration.zero);
      await cubit.check();

      expect(cubit.state, isA<ConsentSatisfied>());
    },
  );

  test('a published version that is only a typo fix does not re-prompt', () async {
    final repository = await buildRepository();
    final cubit = ConsentCubit(repository);
    await cubit.check();
    await cubit.accept();

    // v2 published, but minAcceptedVersion stays at 1 — the change was not
    // substantive, so nobody is interrupted for it.
    final v2 = documentJson(id: 'privacy', version: 2, minAccepted: 1);
    published = {'privacy': v2, 'index': manifestJson([v2])};

    await repository.refresh();
    await cubit.check();

    expect(cubit.state, isA<ConsentSatisfied>());
  });

  test('a substantive new version re-prompts, and says it is an update', () async {
    final repository = await buildRepository();
    final cubit = ConsentCubit(repository);
    await cubit.check();
    await cubit.accept();

    final v2 = documentJson(id: 'privacy', version: 2, minAccepted: 2);
    published = {'privacy': v2, 'index': manifestJson([v2])};

    await repository.refresh();
    await cubit.check();

    final state = cubit.state;
    expect(state, isA<ConsentRequired>());
    state as ConsentRequired;
    expect(state.isFirstRun, isFalse, reason: 'v1 was accepted before');
    expect(state.pending.single.previouslyAccepted, 1);
    expect(state.pending.single.document.version, 2);
  });

  test(
    'a manifest that says v2 while the document cannot be fetched changes nothing',
    () async {
      final repository = await buildRepository();
      final cubit = ConsentCubit(repository);
      await cubit.check();
      await cubit.accept();

      final v2 = documentJson(id: 'privacy', version: 2, minAccepted: 2);
      published = {'privacy': v2, 'index': manifestJson([v2])};
      unfetchableDocuments = {'privacy'};

      await repository.refresh();
      await cubit.check();

      // The whole point: knowing that v2 exists is not enough to block on.
      // Without its text there is nothing to show, so the app carries on.
      expect(cubit.state, isA<ConsentSatisfied>());
      expect(documentFetches, 1, reason: 'it did try');
    },
  );

  test('a malformed published manifest is refused, not adopted', () async {
    final repository = await buildRepository();
    final cubit = ConsentCubit(repository);
    await cubit.check();
    await cubit.accept();

    // minAcceptedVersion above version: nonsense, and exactly the sort of
    // thing a hand-edit upstream of the build script can produce.
    published = {
      'index': {
        'schema': 1,
        'documents': [
          {
            'id': 'privacy',
            'name': {'en': 'p', 'fa': 'p'},
            'version': 2,
            'minAcceptedVersion': 9,
            'effectiveDate': '2026-09-08',
            'file': 'privacy.json',
            'webPath': {'en': '/p', 'fa': '/fa/p'},
          },
        ],
      },
    };

    await repository.refresh();
    await cubit.check();

    expect(cubit.state, isA<ConsentSatisfied>());
  });

  // ── Parsing ────────────────────────────────────────────────────────

  test('a block type this build has never seen does not lose the rest', () {
    final doc = LegalDocument.fromJson(
      documentJson(id: 'privacy', version: 3, extraBlockType: 'video'),
    );

    expect(doc.sections.single.blocks.first, isA<LegalParagraph>());
    expect(doc.sections.single.blocks.last, isA<LegalUnknownBlock>());
    // And the document knows to say so, rather than quietly showing less
    // than the policy actually contains.
    expect(doc.hasUnrenderableContent, isTrue);
  });

  test('a document missing one language is refused outright', () {
    final json = documentJson(id: 'privacy', version: 1);
    (json['sections'] as List).first['title'] = {'en': 'Only English'};

    expect(
      () => LegalDocument.fromJson(json),
      throwsA(isA<LegalFormatException>()),
    );
  });

  test('a future schema is refused rather than guessed at', () {
    final json = documentJson(id: 'privacy', version: 1)..['schema'] = 2;
    expect(
      () => LegalDocument.fromJson(json),
      throwsA(isA<LegalFormatException>()),
    );
  });

  // ── The shipped documents ──────────────────────────────────────────

  test('the JSON generated for the app parses, in both languages', () async {
    // Reads the real generated assets, so a change to the source documents
    // that the app cannot render fails here rather than on a phone.
    final manifest = LegalManifest.fromJson(
      jsonDecode(await _readAsset('assets/legal/index.json'))
          as Map<String, dynamic>,
    );
    expect(manifest.documents, isNotEmpty);

    for (final ref in manifest.documents) {
      final doc = LegalDocument.fromJson(
        jsonDecode(await _readAsset('assets/legal/${ref.file}'))
            as Map<String, dynamic>,
      );
      expect(doc.id, ref.id);
      expect(doc.version, ref.version, reason: 'manifest and document agree');
      expect(doc.sections, isNotEmpty);
      expect(
        doc.hasUnrenderableContent,
        isFalse,
        reason: '${ref.id} contains a block this build cannot render',
      );
      // Both languages reach every leaf, which is what the website build
      // enforces on its side.
      for (final section in doc.sections) {
        expect(section.title.en, isNotEmpty);
        expect(section.title.fa, isNotEmpty);
      }
    }
  });
}

Future<String> _readAsset(String path) async {
  // The assets are ordinary files in the repository; reading them directly
  // keeps this a plain unit test with no binding to initialise.
  return await File(path).readAsString();
}

/// A [LegalRepository] wired to two in-memory JSON stores instead of the
/// asset bundle and the network, so the rules above can be tested without
/// either.
class _FakeBackedRepository implements LegalRepository {
  _FakeBackedRepository({
    required this.readBundled,
    required this.readPublished,
    required this.prefs,
  });

  final Map<String, dynamic>? Function(String name) readBundled;
  final Map<String, dynamic>? Function(String name) readPublished;
  final SharedPreferences prefs;

  ({LegalManifest manifest, Map<String, LegalDocument> documents})? _fetched;

  LegalManifest get _bundledManifest =>
      LegalManifest.fromJson(readBundled('index')!);

  @override
  Future<SourcedManifest> currentManifest() async {
    final fetched = _fetched;
    if (fetched != null) {
      return SourcedManifest(fetched.manifest, LegalSource.remote);
    }
    return SourcedManifest(_bundledManifest, LegalSource.bundled);
  }

  @override
  Future<LegalDocument?> document(LegalDocumentRef ref) async {
    final downloaded = _fetched?.documents[ref.id];
    if (downloaded != null && downloaded.version == ref.version) {
      return downloaded;
    }
    final json = readBundled(ref.id);
    return json == null ? null : LegalDocument.fromJson(json);
  }

  @override
  Future<SourcedManifest> refresh() async {
    final raw = readPublished('index');
    if (raw == null) return currentManifest();

    final LegalManifest published;
    try {
      published = LegalManifest.fromJson(raw);
    } on LegalFormatException {
      return currentManifest();
    }

    final bundled = _bundledManifest;
    final newer = published.documents.where((ref) {
      final local = bundled.byId(ref.id);
      return local == null || ref.version > local.version;
    }).toList();
    if (newer.isEmpty) {
      _fetched = null;
      return SourcedManifest(bundled, LegalSource.bundled);
    }

    final documents = <String, LegalDocument>{};
    for (final ref in newer) {
      final json = readPublished(ref.id);
      if (json == null) return currentManifest();
      documents[ref.id] = LegalDocument.fromJson(json);
    }
    _fetched = (manifest: published, documents: documents);
    return SourcedManifest(published, LegalSource.remote);
  }

  @override
  Future<int?> acceptedVersion(String documentId) async =>
      prefs.getInt(LegalKeys.accepted(documentId));

  @override
  Future<void> recordAcceptance(Map<String, int> versionsById) async {
    for (final entry in versionsById.entries) {
      await prefs.setInt(LegalKeys.accepted(entry.key), entry.value);
    }
  }
}
