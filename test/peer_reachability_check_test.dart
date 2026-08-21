import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/peer_reachability_check.dart';

void main() {
  final s = AppLocalizationsEn();

  test(
    'no peer yet is unknown, never a failure — the issue\'s own '
    '"peer not yet present" warning-only case',
    () {
      final check = peerReachabilityCheck(s: s, unheardByPeers: null);
      expect(check.status, RecoveryStatus.unknown);
      expect(check.code, PreflightCheckCode.peerNotPresent);
    },
  );

  test(
    'peer present but outgoing audibility unconfirmed warns, does not '
    'block — unlike the mid-channel sheet, "hasn\'t said yet" isn\'t failure '
    'the instant a peer appears',
    () {
      final check = peerReachabilityCheck(s: s, unheardByPeers: true);
      expect(check.status, RecoveryStatus.warn);
      expect(check.code, PreflightCheckCode.peerUnconfirmed);
    },
  );

  test('the peer has confirmed hearing us is ok', () {
    final check = peerReachabilityCheck(s: s, unheardByPeers: false);
    expect(check.status, RecoveryStatus.ok);
    expect(check.code, PreflightCheckCode.peerConfirmed);
  });
}
