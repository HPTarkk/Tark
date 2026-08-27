import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/presentation/widget/walkie_header.dart';

void main() {
  group('WalkieHeaderLayout', () {
    test('keeps decorative title out of the 320px Ride Mode header', () {
      expect(WalkieHeaderLayout.showAppTitle(320), isFalse);
      expect(WalkieHeaderLayout.showAppTitle(389), isFalse);
    });

    test('restores the app title when the header has spare width', () {
      expect(WalkieHeaderLayout.showAppTitle(390), isTrue);
      expect(WalkieHeaderLayout.showAppTitle(480), isTrue);
    });
  });
}
