import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/profile_readiness_check.dart';

void main() {
  final s = AppLocalizationsEn();

  group('pre-connect (no live session yet)', () {
    test('reports local HD capability as ok, never a failure', () {
      final check = profileReadinessCheck(s: s, hdVoiceEnabled: true);
      expect(check.status, RecoveryStatus.ok);
      expect(check.code, PreflightCheckCode.hdVoiceReady);
    });

    test(
      'HD Voice turned off reports standard voice, not "ready" — this '
      "build's own supported list won't offer HD, so claiming ready would "
      'be stale',
      () {
        final check = profileReadinessCheck(s: s, hdVoiceEnabled: false);
        expect(check.status, RecoveryStatus.ok);
        expect(check.code, PreflightCheckCode.hdVoiceStandard);
      },
    );
  });

  group('post-connect (a live negotiated format is known)', () {
    test('hd24k negotiated with the peer is ok', () {
      final check = profileReadinessCheck(
        s: s,
        hdVoiceEnabled: true,
        liveNegotiatedFormat: AudioFormatProfile.hd24k,
      );
      expect(check.status, RecoveryStatus.ok);
      expect(check.code, PreflightCheckCode.hdVoiceNegotiatedHd);
    });

    test(
      'a peer without HD support falls back to standard, still ok — '
      'unsupported HD is never a failure if standard voice works',
      () {
        final check = profileReadinessCheck(
          s: s,
          hdVoiceEnabled: true,
          liveNegotiatedFormat: AudioFormatProfile.legacy16k,
        );
        expect(check.status, RecoveryStatus.ok);
        expect(check.code, PreflightCheckCode.hdVoiceStandard);
      },
    );
  });
}
