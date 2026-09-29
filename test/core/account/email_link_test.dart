import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/account/account_models.dart';
import 'package:tark/core/account/email_link.dart';

void main() {
  group('EmailLink.parse', () {
    test('reads the flow and the token after #', () {
      final link = EmailLink.parse(
        Uri.parse('https://tarkk.ir/v/register#abc_DEF-123'),
      );
      expect(link!.kind, FlowKind.register);
      expect(link.token, 'abc_DEF-123');

      final reset = EmailLink.parse(Uri.parse('https://tarkk.ir/v/reset#x'));
      expect(reset!.kind, FlowKind.reset);
    });

    test('an email-change link parses but has no flow the app runs', () {
      final link = EmailLink.parse(Uri.parse('https://tarkk.ir/v/email#x'));
      expect(link, isNotNull);
      expect(link!.kind, isNull);
    });

    test('anything else is not an email link', () {
      for (final raw in [
        'tark://widget/walkie',
        'http://tarkk.ir/v/register#x',
        'https://evil.example/v/register#x',
        'https://tarkk.ir/privacy.html',
        'https://tarkk.ir/v/register',
        'https://tarkk.ir/v/other#x',
        'https://tarkk.ir/v/register/more#x',
      ]) {
        expect(EmailLink.parse(Uri.parse(raw)), isNull, reason: raw);
      }
    });
  });

  group('EmailLinkDispatcher', () {
    const link = EmailLink(segment: 'register', token: 't');

    test('an open code screen for the flow takes the link', () async {
      final dispatcher = EmailLinkDispatcher();
      final unclaimed = <EmailLink>[];
      dispatcher.unclaimed.listen(unclaimed.add);
      final taken = <String>[];
      final release = dispatcher.claim(FlowKind.register, (l) {
        taken.add(l.token);
        return true;
      });

      dispatcher.dispatch(link);
      await Future<void>.delayed(Duration.zero);
      expect(taken, ['t']);
      expect(unclaimed, isEmpty);

      release();
      dispatcher.dispatch(link);
      await Future<void>.delayed(Duration.zero);
      expect(unclaimed, hasLength(1));
    });

    test('a screen for the other flow does not take it', () async {
      final dispatcher = EmailLinkDispatcher();
      final unclaimed = <EmailLink>[];
      dispatcher.unclaimed.listen(unclaimed.add);
      dispatcher.claim(FlowKind.reset, (_) => true);
      dispatcher.dispatch(link);
      await Future<void>.delayed(Duration.zero);
      expect(unclaimed, hasLength(1));
    });
  });
}
