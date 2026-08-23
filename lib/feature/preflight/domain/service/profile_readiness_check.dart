import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../entity/preflight_check_code.dart';

/// Check 3 — audio profile/capability readiness.
///
/// [liveNegotiatedFormat] is null when there is no open session yet (the
/// normal Preflight sheet runs before a peer exists), in which case this
/// reports local build capability only, gated on [hdVoiceEnabled] (the
/// caller's already-read [AudioFormatProfile.hdVoiceEnabled]). When it's on,
/// [AudioFormatProfile.supported]'s first entry has been
/// [AudioFormatProfile.hd24k] in every build since #28's checkpoint 4 — that
/// makes "HD Voice ready" a build-time fact, never a failure, pre-connect.
/// When the user has turned HD Voice off, [supported] is legacy-only, so
/// pre-connect must report the same "standard voice" status the post-connect
/// branch below reports for a peer without HD support — otherwise the row
/// would claim "ready" for a capability this build won't even offer. Once a
/// session exists, pass the transport's actual [AudioFormatProfile] (see
/// `TransferRepository.negotiatedFormat`) to report the real mutual value
/// instead — unsupported HD is still never a failure, per the issue's own
/// rule, since standard voice works.
RecoveryCheck profileReadinessCheck({
  required AppLocalizations s,
  required bool hdVoiceEnabled,
  AudioFormatProfile? liveNegotiatedFormat,
}) {
  if (liveNegotiatedFormat == null) {
    if (!hdVoiceEnabled) {
      return RecoveryCheck(
        label: s.preflight_check_hd_voice,
        detail: s.preflight_hd_voice_standard,
        status: RecoveryStatus.ok,
        code: PreflightCheckCode.hdVoiceStandard,
      );
    }
    return RecoveryCheck(
      label: s.preflight_check_hd_voice,
      detail: s.preflight_hd_voice_ready,
      status: RecoveryStatus.ok,
      code: PreflightCheckCode.hdVoiceReady,
    );
  }
  if (liveNegotiatedFormat == AudioFormatProfile.hd24k) {
    return RecoveryCheck(
      label: s.preflight_check_hd_voice,
      detail: s.preflight_hd_voice_negotiated_hd,
      status: RecoveryStatus.ok,
      code: PreflightCheckCode.hdVoiceNegotiatedHd,
    );
  }
  return RecoveryCheck(
    label: s.preflight_check_hd_voice,
    detail: s.preflight_hd_voice_standard,
    status: RecoveryStatus.ok,
    code: PreflightCheckCode.hdVoiceStandard,
  );
}
