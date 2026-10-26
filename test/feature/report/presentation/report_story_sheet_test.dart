import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/report/api/report_api.dart';
import 'package:tark/feature/report/presentation/widget/report_story_sheet.dart';

/// Set `REPORT_SHOTS=<dir>` to write the story's frames out as PNGs.
final _shots = Platform.environment['REPORT_SHOTS'];

final _boundary = GlobalKey();

Widget _app({
  required void Function(BuildContext) open,
  bool reduced = false,
  String lang = 'en',
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(fontFamily: 'Vazirmatn', brightness: Brightness.dark),
  locale: Locale(lang),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: reduced, size: const Size(390, 844)),
    child: RepaintBoundary(key: _boundary, child: child!),
  ),
  home: Scaffold(
    backgroundColor: const Color(0xFF0B0E11),
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const Key('open'),
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

MemberSubject _roomMember() => MemberSubject(
  name: 'Kian',
  seed: 'member-kian',
  avatar: (size) => SizedBox(width: size, height: size),
  roomId: 'room-1',
  roomName: 'Sunday ride',
  memberId: 'member-kian',
  senderId: 'sender-kian',
);

/// Advances [ms] milliseconds as real frames, so implicit animations that
/// start mid-way (AnimatedSize, the springs) actually run.
Future<void> _run(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _openStory(
  WidgetTester tester, {
  required MemberSubject subject,
  required ListenerMutes mutes,
  required Future<bool> Function(Uri) launchMail,
  bool reduced = false,
  String lang = 'en',
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      reduced: reduced,
      lang: lang,
      open: (context) => showReportStory(
        context,
        subject: subject,
        mutes: mutes,
        launchMail: launchMail,
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pump();
  // The sheet's own rise.
  await _run(tester, 600);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final fonts = FontLoader('Vazirmatn')
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Black.ttf'));
    await fonts.load();
    final iconsPath =
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(iconsPath).existsSync()) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(File(iconsPath).readAsBytesSync())),
        );
      await icons.load();
    }
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tells the story, then mutes and opens a prefilled email', (
    tester,
  ) async {
    final mutes = ListenerMutes();
    Uri? sent;
    await _openStory(
      tester,
      subject: _roomMember(),
      mutes: mutes,
      launchMail: (uri) async {
        sent = uri;
        return true;
      },
    );

    // Mid-intro: the words are flying, nothing to pick yet.
    await _run(tester, 800);
    await _shot(tester, 'en-1-intro');
    expect(find.byKey(const Key('report-reason-insult')), findsNothing);

    await _run(tester, 2000);
    expect(find.text('Did Kian spoil the ride?'), findsOneWidget);
    expect(find.byKey(const Key('report-reason-insult')), findsOneWidget);
    expect(find.byKey(const Key('report-send')), findsNothing);
    await _shot(tester, 'en-2-choose');

    await tester.tap(find.byKey(const Key('report-reason-insult')));
    await _run(tester, 300);
    await _shot(tester, 'en-3-punch');
    await _run(tester, 1400);
    await _shot(tester, 'en-4-dome');

    // Mute is the pre-selected default, but nothing is muted until sent.
    expect(find.byKey(const Key('report-send')), findsOneWidget);
    expect(find.text('Mute Kian for me'), findsOneWidget);
    expect(mutes.isMemberMuted('room-1', 'member-kian'), isFalse);

    await tester.ensureVisible(find.byKey(const Key('report-send')));
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-send')));
    await _run(tester, 500);
    await _shot(tester, 'en-5-envelope');
    await _run(tester, 900);
    await _run(tester, 400);
    await _shot(tester, 'en-6-done');

    expect(mutes.isMemberMuted('room-1', 'member-kian'), isTrue);
    expect(mutes.isSenderMuted('sender-kian'), isTrue);
    expect(sent, isNotNull);
    expect(sent!.scheme, 'mailto');
    expect(sent!.path, 'tarkk.hp@gmail.com');
    final query = sent!.query;
    expect(query, isNot(contains('+')));
    final subject = Uri.decodeComponent(
      RegExp(r'subject=([^&]*)').firstMatch(query)!.group(1)!,
    );
    final body = Uri.decodeComponent(
      RegExp(r'body=([^&]*)').firstMatch(query)!.group(1)!,
    );
    expect(subject, 'Tarkk report: Insults or swearing');
    expect(body, contains('Reported person: Kian'));
    expect(body, contains('Room: Sunday ride'));
    expect(body, contains('Member ID: member-kian'));
    expect(find.text('Thanks for speaking up'), findsOneWidget);
    expect(find.text('Kian stays muted for you.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('report-done')));
    await tester.pump();
    await _run(tester, 1000);
    expect(find.byType(ReportStorySheet), findsNothing);
  });

  testWidgets('turning the mute off sends the report and mutes nobody', (
    tester,
  ) async {
    final mutes = ListenerMutes();
    await _openStory(
      tester,
      subject: _roomMember(),
      mutes: mutes,
      launchMail: (_) async => true,
    );
    await _run(tester, 2800);
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-reason-threat')));
    await _run(tester, 1500);

    await tester.ensureVisible(find.byKey(const Key('report-mute-toggle')));
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-mute-toggle')));
    await _run(tester, 1500);
    await tester.ensureVisible(find.byKey(const Key('report-send')));
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-send')));
    await _run(tester, 1500);
    await _run(tester, 400);

    expect(find.text('Thanks for speaking up'), findsOneWidget);
    expect(mutes.isMemberMuted('room-1', 'member-kian'), isFalse);
    expect(find.text('Kian stays muted for you.'), findsNothing);
  });

  testWidgets('without a mail app the report is offered to copy', (
    tester,
  ) async {
    await _openStory(
      tester,
      subject: _roomMember(),
      mutes: ListenerMutes(),
      launchMail: (_) async => false,
      reduced: true,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('report-reason-spam')));
    await _run(tester, 1000);
    await tester.ensureVisible(find.byKey(const Key('report-send')));
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-send')));
    await tester.pump();
    await _run(tester, 400);

    expect(find.text('No email app found'), findsOneWidget);
    expect(find.byKey(const Key('report-copy')), findsOneWidget);
  });

  testWidgets('reduced motion starts at the choice, with no ambient loop', (
    tester,
  ) async {
    await _openStory(
      tester,
      subject: _roomMember(),
      mutes: ListenerMutes(),
      launchMail: (_) async => true,
      reduced: true,
    );
    await tester.pump();
    await _run(tester, 400);
    expect(find.byKey(const Key('report-reason-insult')), findsOneWidget);
    // Nothing loops forever under reduced motion, so the sheet can settle.
    await tester.pumpAndSettle();
    await _shot(tester, 'en-reduced');
  });

  testWidgets('a quick-channel peer is muted for this session only', (
    tester,
  ) async {
    final mutes = ListenerMutes();
    await _openStory(
      tester,
      subject: MemberSubject(
        name: 'Rider',
        seed: 'sender-9',
        avatar: (size) => SizedBox(width: size, height: size),
        senderId: 'sender-9',
      ),
      mutes: mutes,
      launchMail: (_) async => true,
      reduced: true,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('report-reason-profile')));
    await _run(tester, 400);
    await tester.ensureVisible(find.byKey(const Key('report-send')));
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-send')));
    await tester.pump();
    await _run(tester, 400);
    expect(mutes.isSenderMuted('sender-9'), isTrue);
  });

  testWidgets('Persian: mirrored stage and Persian copy', (tester) async {
    final mutes = ListenerMutes();
    Uri? sent;
    await _openStory(
      tester,
      subject: _roomMember(),
      mutes: mutes,
      launchMail: (uri) async {
        sent = uri;
        return true;
      },
      lang: 'fa',
    );
    await _run(tester, 1500);
    await _shot(tester, 'fa-1-intro');
    await _run(tester, 1900);
    expect(find.text('Kian حالت رو گرفت؟'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-reason-profile')));
    await _run(tester, 1700);
    await _shot(tester, 'fa-2-dome');
    await tester.ensureVisible(find.byKey(const Key('report-send')));
    await _run(tester, 500);
    await tester.tap(find.byKey(const Key('report-send')));
    await _run(tester, 1500);
    await _run(tester, 400);
    await _shot(tester, 'fa-3-done');
    final query = sent!.query;
    final subject = Uri.decodeComponent(
      RegExp(r'subject=([^&]*)').firstMatch(query)!.group(1)!,
    );
    expect(subject, 'گزارش تخلف تَرک: اسم یا عکس زشت');
    expect(find.text('ممنون که گفتی'), findsOneWidget);
  });
}
