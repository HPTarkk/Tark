import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/domain/service/channel_roster.dart';

ChannelUser user(
  String id, {
  bool isTalking = false,
  DateTime? lastSeen,
}) => ChannelUser(
  id: id,
  name: 'User $id',
  isTalking: isTalking,
  lastSeen: lastSeen ?? DateTime.now(),
);

void main() {
  const roster = ChannelRoster();

  group('ChannelRoster.upsert', () {
    test('new user is added and reported as a join', () {
      final update = roster.upsert([], user('a'));
      expect(update.change, RosterChange.peerJoined);
      expect(update.users.single.id, 'a');
    });

    test('silent → talking reports a talk onset', () {
      final update = roster.upsert(
        [user('a')],
        user('a', isTalking: true),
      );
      expect(update.change, RosterChange.peerStartedTalking);
      expect(update.users.single.isTalking, isTrue);
    });

    test('talking → talking refresh reports no change', () {
      final update = roster.upsert(
        [user('a', isTalking: true)],
        user('a', isTalking: true),
      );
      expect(update.change, RosterChange.none);
    });

    test('talking → silent reports no change (timeout owns the cue)', () {
      final update = roster.upsert(
        [user('a', isTalking: true)],
        user('a'),
      );
      expect(update.change, RosterChange.none);
      expect(update.users.single.isTalking, isFalse);
    });

    test('does not mutate the input list', () {
      final input = [user('a')];
      roster.upsert(input, user('b'));
      expect(input, hasLength(1));
    });
  });

  group('ChannelRoster.cleanup', () {
    final now = DateTime(2026, 7, 20, 12);

    test('drops users unseen past staleAfterSeconds and reports a leave', () {
      final update = roster.cleanup(
        [user('a', lastSeen: now.subtract(const Duration(seconds: 8)))],
        now,
      );
      expect(update.change, RosterChange.peerLeft);
      expect(update.users, isEmpty);
    });

    test('silences a talker unseen past talkTimeoutSeconds but keeps them', () {
      final update = roster.cleanup(
        [
          user(
            'a',
            isTalking: true,
            lastSeen: now.subtract(const Duration(seconds: 4)),
          ),
        ],
        now,
      );
      expect(update.change, RosterChange.none);
      expect(update.users.single.isTalking, isFalse);
    });

    test('fresh users pass through untouched', () {
      final update = roster.cleanup(
        [user('a', isTalking: true, lastSeen: now)],
        now,
      );
      expect(update.change, RosterChange.none);
      expect(update.users.single.isTalking, isTrue);
    });
  });
}
