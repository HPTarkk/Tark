import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/signed_entitlement.dart';
import 'package:tark/core/entitlement/subscription_policy.dart';

SignedEntitlement _token({
  EntitlementStatus status = EntitlementStatus.active,
  required DateTime? until,
  bool autoRenewing = true,
  bool suspicious = false,
  required DateTime issuedAt,
}) => SignedEntitlement(
  raw: 'raw',
  accountId: 'acct',
  installKey: 'ik',
  status: status,
  sku: 'tark_premium_1m',
  until: until,
  autoRenewing: autoRenewing,
  suspicious: suspicious,
  issuedAt: issuedAt,
  policy: const EntitlementPolicy(
    grace: Duration(hours: 72),
    refreshWindow: Duration(days: 5),
    suspiciousOfflineLimit: Duration(days: 3),
  ),
);

void main() {
  final issued = DateTime.utc(2026, 10, 1);
  final until = DateTime.utc(2026, 11, 1);

  SubscriptionAccess at(SignedEntitlement? token, DateTime now) =>
      SubscriptionPolicy.evaluate(token, now);

  group('no data', () {
    test('no token needs a check', () {
      final access = at(null, issued);
      expect((access as AccessNeedsCheck).reason, CheckReason.noData);
    });

    test('never subscribed needs a check', () {
      final token = _token(
        status: EntitlementStatus.none,
        until: null,
        issuedAt: issued,
      );
      expect(
        (at(token, issued) as AccessNeedsCheck).reason,
        CheckReason.noData,
      );
    });
  });

  group('valid subscription', () {
    test('works offline with no refresh while far from the end', () {
      final access = at(_token(until: until, issuedAt: issued), issued);
      expect(access, isA<AccessGranted>());
      expect((access as AccessGranted).refreshSuggested, isFalse);
    });

    test('suggests a quiet refresh inside the refresh window', () {
      final now = until.subtract(const Duration(days: 2));
      final access = at(_token(until: until, issuedAt: issued), now);
      expect((access as AccessGranted).refreshSuggested, isTrue);
    });

    test('auto-renew switched off is not suspicious and keeps access', () {
      final token = _token(until: until, autoRenewing: false, issuedAt: issued);
      expect(
        at(token, until.subtract(const Duration(days: 10))),
        isA<AccessGranted>(),
      );
    });
  });

  group('after the period ends', () {
    test('auto-renewing gets the grace period', () {
      final access = at(
        _token(until: until, issuedAt: issued),
        until.add(const Duration(hours: 71)),
      );
      expect((access as AccessGranted).inGrace, isTrue);
    });

    test('grace runs out', () {
      final access = at(
        _token(until: until, issuedAt: issued),
        until.add(const Duration(hours: 72)),
      );
      expect((access as AccessNeedsCheck).reason, CheckReason.expired);
    });

    test('no grace when auto-renew is off', () {
      final access = at(
        _token(until: until, autoRenewing: false, issuedAt: issued),
        until,
      );
      expect((access as AccessNeedsCheck).reason, CheckReason.expired);
    });

    test('expired and refunded statuses need a check', () {
      for (final status in [
        EntitlementStatus.expired,
        EntitlementStatus.refunded,
      ]) {
        final access = at(
          _token(status: status, until: until, issuedAt: issued),
          issued,
        );
        expect((access as AccessNeedsCheck).reason, CheckReason.expired);
      }
    });
  });

  group('conservative mode', () {
    test('works offline while the last check is recent', () {
      final token = _token(until: until, suspicious: true, issuedAt: issued);
      final access = at(token, issued.add(const Duration(days: 2)));
      expect(access, isA<AccessGranted>());
      expect((access as AccessGranted).refreshSuggested, isTrue);
    });

    test('needs a check once the last one is older than the limit', () {
      final token = _token(until: until, suspicious: true, issuedAt: issued);
      final access = at(token, issued.add(const Duration(days: 3)));
      expect((access as AccessNeedsCheck).reason, CheckReason.staleCheck);
    });

    test('gets no grace after the period ends', () {
      final token = _token(until: until, suspicious: true, issuedAt: until);
      final access = at(token, until.add(const Duration(hours: 1)));
      expect((access as AccessNeedsCheck).reason, CheckReason.expired);
    });
  });
}
