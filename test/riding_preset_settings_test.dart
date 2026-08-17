import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/settings/app_settings.dart';
import 'package:tark/core/settings/audio_profile.dart';
import 'package:tark/core/settings/noise_suppression_engine.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';

/// The riding preset as it behaves through real persistence, which is where
/// "override, never overwrite" either holds or quietly doesn't.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsRepositoryImpl> repo([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return SettingsRepositoryImpl(await SharedPreferences.getInstance());
  }

  test('a fresh install runs the stored defaults, not the preset', () async {
    final r = await repo();
    final profile = await r.getAudioProfile();
    expect(profile.fromPreset, isFalse);
    expect(profile.voxMargin, AppSettings.defaults().voxMargin);
    expect(profile.playbackGain, 1.0);
  });

  test('turning it on changes the profile without touching a stored knob', () async {
    final r = await repo();
    await r.setVoxMargin(0.11);
    await r.setNoiseSuppression(0.25);
    await r.setNoiseSuppressionEngine(NoiseSuppressionEngine.spectral);
    await r.setTargetBufferMs(240);

    await r.setRidingPreset(true);

    // What runs is the preset's.
    expect(await r.getAudioProfile(), RidingPreset.profile);
    // What is stored is still theirs, to the digit. This is the property the
    // whole design rests on — a rider who tries the switch mid-ride and hates
    // it has to get their own setup back, not the factory's.
    expect(await r.getVoxMargin(), 0.11);
    expect(await r.getNoiseSuppression(), 0.25);
    expect(await r.getTargetBufferMs(), 240);
    expect(
      await r.getNoiseSuppressionEngine(),
      NoiseSuppressionEngine.spectral,
    );
  });

  test('turning it back off restores exactly what was there', () async {
    final r = await repo();
    await r.setVoxMargin(0.11);
    await r.setNoiseSuppression(0.25);
    await r.setTargetBufferMs(240);
    final before = await r.getAudioProfile();

    await r.setRidingPreset(true);
    await r.setRidingPreset(false);

    expect(await r.getAudioProfile(), before);
  });

  test('"reset to normal" turns the preset off too', () async {
    // Otherwise the button restores three values the preset immediately
    // overrides again, and reads to the user as broken.
    final r = await repo();
    await r.setVoxMargin(0.11);
    await r.setRidingPreset(true);

    await r.restoreVoiceDefaults();

    expect(await r.getRidingPreset(), isFalse);
    final profile = await r.getAudioProfile();
    expect(profile.fromPreset, isFalse);
    expect(profile.voxMargin, AppSettings.defaults().voxMargin);
    expect(profile.noiseSuppression, AppSettings.defaults().noiseSuppression);
    expect(profile.targetBufferMs, AppSettings.defaults().targetBufferMs);
  });

  test('loadAll and getAudioProfile agree about the switch', () async {
    // Two readers of the same preference; a disagreement here would show as a
    // settings page drawing one state while the engine runs the other.
    final r = await repo();
    await r.setRidingPreset(true);
    expect((await r.loadAll()).ridingPreset, isTrue);
    expect((await r.getAudioProfile()).fromPreset, isTrue);
  });

  test('an install predating the preset reads as off, not as missing', () async {
    // The key simply isn't in prefs on upgrade. Defaulting it to anything but
    // false would change the audio chain under an existing user without them
    // asking.
    final r = await repo({'vox_threshold': 0.05});
    expect(await r.getRidingPreset(), isFalse);
    // The stored VOX value is the legacy absolute one, so the profile reports
    // it on the margin scale — 0.05 of the old 0.15 full scale is the same
    // one-third of the slider the user was already looking at. See
    // VoxMargin.fromLegacyThreshold.
    expect((await r.getAudioProfile()).voxMargin, closeTo(1 / 3, 1e-9));
  });
}
