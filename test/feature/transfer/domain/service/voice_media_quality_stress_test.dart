import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/transfer/domain/service/media_quality_controller.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';
import 'package:tark/feature/transfer/domain/service/voice_quality_controller.dart';

/// #32's deterministic stress/replay fixture for the two adaptive tier
/// controllers checkpoints 1 and 3 built — the roadmap's own instruction:
/// "deterministic condition sequences (not real timers)" modeling realistic
/// motorcycle conditions (clean baseline, short bursts, an RTT spike,
/// recovery, sustained trouble). Every other test file in this issue proves
/// one controller in isolation; this one proves the cross-cutting invariants
/// the roadmap actually cares about — that voice and media react
/// *independently* to the same measured link, that a brief blip doesn't
/// cause either to flap, and that identical conditions replay identically.
///
/// Both controllers here run on their real production default windows (no
/// shortened evidence/dwell like the per-class unit tests use) — the point of
/// this fixture is to prove the shipped timings behave sanely end to end, not
/// to exercise the mechanism quickly.
///
/// [Frame] steps are hand-authored to model a ride, not randomly generated:
/// the roadmap asks for specific named conditions (baseline, burst, spike,
/// recovery), which a seeded RNG would obscure rather than clarify.
class _Frame {
  const _Frame(this.conditions, this.elapsedMs);
  final AudioLinkConditions conditions;
  final int elapsedMs;
}

const _clean = AudioLinkConditions(lossFraction: 0.0);
const _poorForVoiceOnly = AudioLinkConditions(
  lossFraction: 0.20,
); // above voice's 15% bar, below media's 25% failing bar
const _failing = AudioLinkConditions(lossFraction: 0.30); // fails both
const _rttSpike = AudioLinkConditions(
  lossFraction: 0.0,
  rtt: Duration(milliseconds: 300),
);

/// Repeats [conditions] as a series of 2s ticks — the same cadence
/// `WifiTransferRepositoryImpl._pingPeers` measures the link at — totalling
/// [totalMs].
List<_Frame> _hold(AudioLinkConditions conditions, int totalMs) {
  const tick = 2000;
  final frames = <_Frame>[];
  var remaining = totalMs;
  while (remaining > 0) {
    final step = remaining < tick ? remaining : tick;
    frames.add(_Frame(conditions, step));
    remaining -= step;
  }
  return frames;
}

void _run(
  List<_Frame> frames,
  VoiceQualityController voice,
  MediaQualityController media,
) {
  for (final f in frames) {
    voice.advance(
      conditions: f.conditions,
      ceiling: AudioFormatProfile.hd24k,
      elapsedMs: f.elapsedMs,
    );
    media.advance(conditions: f.conditions, elapsedMs: f.elapsedMs);
  }
}

void main() {
  group('voice + media adaptive policy under realistic conditions', () {
    test('a clean link brings voice up to HD while media runs the whole time '
        'without ever suspending — independent controllers, same evidence', () {
      final voice = VoiceQualityController();
      final media = MediaQualityController();

      _run(_hold(_clean, 24000), voice, media);

      expect(voice.profile, AudioFormatProfile.hd24k);
      expect(media.tier, MediaSendTier.active);
    });

    test(
      'a link poor enough to hold voice back is not poor enough to threaten '
      'media — media is not needlessly punished for a voice-only problem',
      () {
        final voice = VoiceQualityController();
        final media = MediaQualityController();
        // Warm both up on a clean baseline first.
        _run(_hold(_clean, 24000), voice, media);
        expect(voice.profile, AudioFormatProfile.hd24k);

        // 20% loss: past voice's poor bar (15%), nowhere near media's
        // failing bar (25%).
        _run(_hold(_poorForVoiceOnly, 6000), voice, media);

        expect(voice.profile, AudioFormatProfile.legacy16k);
        expect(media.tier, MediaSendTier.active);
      },
    );

    test('a brief RTT spike does not cause either controller to flap', () {
      final voice = VoiceQualityController();
      final media = MediaQualityController();
      _run(_hold(_clean, 24000), voice, media);
      expect(voice.profile, AudioFormatProfile.hd24k);

      // 1s spike: shorter than either controller's downgrade evidence
      // window (voice 4s, media has no congestion-alone downgrade at all).
      final spikeTransitionVoice = voice.advance(
        conditions: _rttSpike,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 1000,
      );
      final spikeTransitionMedia = media.advance(
        conditions: _rttSpike,
        elapsedMs: 1000,
      );
      expect(spikeTransitionVoice, isNull);
      expect(spikeTransitionMedia, isNull);

      // Recovers immediately — the bad-evidence clock reset, it never had
      // a chance to bank a real downgrade.
      _run(_hold(_clean, 2000), voice, media);
      expect(voice.profile, AudioFormatProfile.hd24k);
      expect(media.tier, MediaSendTier.active);
    });

    test('sustained failing loss suspends media while voice merely falls to '
        'its own floor — media absorbs the deeper cut it alone can afford', () {
      final voice = VoiceQualityController();
      final media = MediaQualityController();
      _run(_hold(_clean, 24000), voice, media);
      expect(voice.profile, AudioFormatProfile.hd24k);

      // Long enough to cross both voice's downgrade window (4s) and
      // media's (8s).
      _run(_hold(_failing, 20000), voice, media);

      // Voice has nowhere lower to go than its permanent floor.
      expect(voice.profile, AudioFormatProfile.legacy16k);
      expect(media.tier, MediaSendTier.suspended);
    });

    test('recovery requires sustained clean evidence in both directions, '
        'each controller timed independently of the other', () {
      final voice = VoiceQualityController();
      final media = MediaQualityController();
      _run(_hold(_clean, 24000), voice, media);
      _run(_hold(_failing, 20000), voice, media);
      expect(voice.profile, AudioFormatProfile.legacy16k);
      expect(media.tier, MediaSendTier.suspended);

      // Voice's upgrade window (15s) is shorter than media's resume
      // window (20s) — voice should recover first.
      _run(_hold(_clean, 16000), voice, media);
      expect(voice.profile, AudioFormatProfile.hd24k);
      expect(media.tier, MediaSendTier.suspended);

      // The rest of media's longer window elapses.
      _run(_hold(_clean, 6000), voice, media);
      expect(voice.profile, AudioFormatProfile.hd24k);
      expect(media.tier, MediaSendTier.active);
    });

    test('deterministic replay: identical condition sequences yield identical '
        'transition sequences', () {
      List<_Frame> ride() => [
        ..._hold(_clean, 24000),
        ..._hold(_poorForVoiceOnly, 6000),
        ..._hold(_clean, 4000),
        const _Frame(_rttSpike, 1000),
        ..._hold(_clean, 2000),
        ..._hold(_failing, 20000),
        ..._hold(_clean, 24000),
      ];

      List<String> replay() {
        final voice = VoiceQualityController();
        final media = MediaQualityController();
        final log = <String>[];
        for (final f in ride()) {
          final vt = voice.advance(
            conditions: f.conditions,
            ceiling: AudioFormatProfile.hd24k,
            elapsedMs: f.elapsedMs,
          );
          if (vt != null) log.add('voice:$vt');
          final mt = media.advance(
            conditions: f.conditions,
            elapsedMs: f.elapsedMs,
          );
          if (mt != null) log.add('media:$mt');
        }
        return log;
      }

      final first = replay();
      final second = replay();

      expect(first, isNotEmpty);
      expect(second, first);
    });
  });
}
