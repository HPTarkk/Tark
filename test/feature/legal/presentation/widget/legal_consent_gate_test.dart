import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/legal/domain/entity/legal_document.dart';
import 'package:tark/feature/legal/domain/entity/legal_manifest.dart';
import 'package:tark/feature/legal/domain/repository/legal_repository.dart';
import 'package:tark/feature/legal/presentation/manager/consent_cubit.dart';
import 'package:tark/feature/legal/presentation/widget/consent_gate.dart';

/// The gate's one visible promise: while there is a document nobody has
/// agreed to, the app is not reachable — and the moment it is agreed to, the
/// app is exactly where it was.
///
/// Worth a widget test rather than trusting the cubit tests alone, because
/// every way of getting this wrong still leaves a cubit that behaves
/// perfectly: a gate rendered behind the child, a `canPop` that lets a back
/// gesture through, a child built anyway and merely covered.
void main() {
  const childMarker = 'THE APP ITSELF';

  Widget harness(ConsentCubit cubit) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ConsentGate(
      cubit: cubit,
      child: const Scaffold(body: Center(child: Text(childMarker))),
    ),
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the app is unreachable until the documents are accepted', (
    tester,
  ) async {
    final repository = _StubRepository();
    final cubit = ConsentCubit(repository);

    await tester.pumpWidget(harness(cubit));
    // Bounded pumps rather than pumpAndSettle: the gate's saving state runs a
    // CircularProgressIndicator, which never settles.
    await tester.pump();
    await tester.pump();

    expect(
      find.text(childMarker),
      findsNothing,
      reason: 'the app must not be built behind the gate, only hidden by it',
    );
    expect(find.text('Before we start'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('WHAT LEAVES YOUR PHONE'), findsOneWidget);

    // The second card is below the fold at this viewport; both documents are
    // on the one screen, and the reader reaches them by scrolling rather than
    // by dismissing anything.
    await tester.scrollUntilVisible(
      find.text('Terms & Conditions'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Terms & Conditions'), findsOneWidget);
    expect(find.text('WHAT YOU GET'), findsOneWidget);

    // The accept bar is outside the scroll view, so it is reachable
    // throughout — a gate whose only exit scrolls off screen is a trap.
    await tester.tap(find.text('I agree — continue'));
    await tester.pump();
    await tester.pump();

    expect(find.text(childMarker), findsOneWidget);
    expect(find.text('Before we start'), findsNothing);
  });

  testWidgets('nothing outstanding means the app is never covered', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'legal_accepted_privacy': 1,
      'legal_accepted_terms': 1,
    });

    await tester.pumpWidget(harness(ConsentCubit(_StubRepository())));
    await tester.pump();
    await tester.pump();

    expect(find.text(childMarker), findsOneWidget);
  });

  testWidgets('a system back gesture is not a way past the gate', (
    tester,
  ) async {
    await tester.pumpWidget(harness(ConsentCubit(_StubRepository())));
    await tester.pump();
    await tester.pump();

    expect(find.text('Before we start'), findsOneWidget);

    // What the OS back button does, as Flutter delivers it.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();

    expect(find.text('Before we start'), findsOneWidget);
    expect(find.text(childMarker), findsNothing);
  });
}

/// Two documents at v1, no network, acceptance in SharedPreferences — the
/// state a phone is in on its first launch.
class _StubRepository implements LegalRepository {
  static Map<String, dynamic> _json(String id, String name, String ledger) => {
    'schema': 1,
    'id': id,
    'name': {'en': name, 'fa': name},
    'version': 1,
    'minAcceptedVersion': 1,
    'effectiveDate': '2026-09-08',
    'effectiveDateLabel': {'en': '8 September 2026', 'fa': '۱۷ شهریور ۱۴۰۵'},
    'webPath': {'en': '/$id.html', 'fa': '/fa/$id.html'},
    'hero': {
      'heading': {'en': 'Heading', 'fa': 'عنوان'},
      'lede': {'en': 'Lede', 'fa': 'مقدمه'},
    },
    'summary': {
      'columns': [
        {
          'kind': 'asks',
          'title': {'en': ledger, 'fa': ledger},
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
        ],
      },
    ],
  };

  static final _documents = {
    'privacy': LegalDocument.fromJson(
      _json('privacy', 'Privacy Policy', 'WHAT LEAVES YOUR PHONE'),
    ),
    'terms': LegalDocument.fromJson(
      _json('terms', 'Terms & Conditions', 'WHAT YOU GET'),
    ),
  };

  @override
  Future<SourcedManifest> currentManifest() async => SourcedManifest(
    LegalManifest.fromJson({
      'schema': 1,
      'documents': [
        for (final id in _documents.keys)
          {
            'id': id,
            'name': {
              'en': _documents[id]!.name.en,
              'fa': _documents[id]!.name.fa,
            },
            'version': 1,
            'minAcceptedVersion': 1,
            'effectiveDate': '2026-09-08',
            'file': '$id.json',
            'webPath': {'en': '/$id.html', 'fa': '/fa/$id.html'},
          },
      ],
    }),
    LegalSource.bundled,
  );

  @override
  Future<LegalDocument?> document(LegalDocumentRef ref) async =>
      _documents[ref.id];

  /// No network in a widget test, and nothing for it to change.
  @override
  Future<SourcedManifest> refresh() => currentManifest();

  @override
  Future<int?> acceptedVersion(String documentId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('legal_accepted_$documentId');
  }

  @override
  Future<void> recordAcceptance(Map<String, int> versionsById) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in versionsById.entries) {
      await prefs.setInt('legal_accepted_${entry.key}', entry.value);
    }
  }
}
