import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/report/api/report_api.dart';

void main() {
  setUpAll(() => ReportConfig.debugOverride = true);
  tearDownAll(() => ReportConfig.debugOverride = null);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stays hidden until it knows whether it was learned', () async {
    final hint = MemberTapHint();
    expect(hint.showing, isFalse);
    await hint.load();
    expect(hint.showing, isTrue);
  });

  test('once learned, never again, across restarts', () async {
    final first = MemberTapHint();
    await first.load();
    var notified = 0;
    first.addListener(() => notified++);
    await first.learned();
    expect(first.showing, isFalse);
    expect(notified, 1);

    final restarted = MemberTapHint();
    await restarted.load();
    expect(restarted.showing, isFalse);
  });

  test('a returning rider who learned it before never sees it', () async {
    SharedPreferences.setMockInitialValues({'member_tap_hint.seen.v1': true});
    final hint = MemberTapHint();
    await hint.load();
    expect(hint.showing, isFalse);
  });

  test('with the build flag off it never shows', () async {
    ReportConfig.debugOverride = false;
    addTearDown(() => ReportConfig.debugOverride = true);
    final hint = MemberTapHint();
    await hint.load();
    expect(hint.showing, isFalse);
  });

  test('without storage it still coaches, and learning sticks', () async {
    final hint = MemberTapHint(prefs: () => Future.error(StateError('no')));
    await hint.load();
    expect(hint.showing, isTrue);
    await hint.learned();
    expect(hint.showing, isFalse);
  });
}
