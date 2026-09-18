import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/presentation/widget/user_list.dart';

void main() {
  group('RideMemberCount', () {
    test('counts local rider when no remote peer is present', () {
      expect(RideMemberCount.total(0), 1);
    });

    test('adds local rider exactly once for 2, 3 and 5 person rooms', () {
      expect(RideMemberCount.total(1), 2);
      expect(RideMemberCount.total(2), 3);
      expect(RideMemberCount.total(4), 5);
    });

    test('rejects an impossible negative remote count', () {
      expect(() => RideMemberCount.total(-1), throwsArgumentError);
    });
  });
}
