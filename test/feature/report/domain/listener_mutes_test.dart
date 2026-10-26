import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/report/domain/listener_mutes.dart';
import 'package:tark/feature/report/domain/report_config.dart';

void main() {
  setUpAll(() => ReportConfig.debugOverride = true);
  tearDownAll(() => ReportConfig.debugOverride = null);
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a muted Room member silences whichever sender they speak as', () async {
    final mutes = ListenerMutes();
    await mutes.setMemberMuted('room', 'ana', true);

    expect(mutes.isMemberMuted('room', 'ana'), isTrue);
    expect(mutes.isSenderMuted('s1'), isFalse);

    mutes.bindSender('room', 'ana', 's1');
    expect(mutes.isSenderMuted('s1'), isTrue);

    // A restarted app is a new sender id; the member stays muted.
    mutes.bindSender('room', 'ana', 's2');
    expect(mutes.isSenderMuted('s2'), isTrue);
  });

  test('binding a member who is not muted mutes nobody', () {
    final mutes = ListenerMutes()..bindSender('room', 'bo', 's1');
    expect(mutes.isSenderMuted('s1'), isFalse);
  });

  test('unmuting a member releases every sender bound to them', () async {
    final mutes = ListenerMutes();
    await mutes.setMemberMuted('room', 'ana', true, senderId: 's1');
    mutes.bindSender('room', 'ana', 's2');

    await mutes.setMemberMuted('room', 'ana', false);

    expect(mutes.isMemberMuted('room', 'ana'), isFalse);
    expect(mutes.isSenderMuted('s1'), isFalse);
    expect(mutes.isSenderMuted('s2'), isFalse);
  });

  test('the same member id in another Room is a different person', () async {
    final mutes = ListenerMutes();
    await mutes.setMemberMuted('room-a', 'ana', true);
    expect(mutes.isMemberMuted('room-b', 'ana'), isFalse);
  });

  test('member mutes survive a restart; sender mutes do not', () async {
    final first = ListenerMutes();
    await first.setMemberMuted('room', 'ana', true);
    first.setSenderMuted('quick', true);

    final second = ListenerMutes();
    await second.load();
    expect(second.isMemberMuted('room', 'ana'), isTrue);
    expect(second.isSenderMuted('quick'), isFalse);
  });

  test('notifies on member changes so open cards and rows update', () async {
    final mutes = ListenerMutes();
    var calls = 0;
    mutes.addListener(() => calls++);
    await mutes.setMemberMuted('room', 'ana', true);
    mutes.setSenderMuted('quick', true);
    mutes.setSenderMuted('quick', true);
    expect(calls, 2);
  });

  test('a storage failure leaves everybody audible', () async {
    final mutes = ListenerMutes(prefs: () async => throw StateError('no'));
    await mutes.load();
    expect(mutes.isMemberMuted('room', 'ana'), isFalse);
    await mutes.setMemberMuted('room', 'ana', true);
    expect(mutes.isMemberMuted('room', 'ana'), isTrue);
  });
}
