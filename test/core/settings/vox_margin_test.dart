import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/settings/app_settings.dart';
import 'package:tark/core/settings/audio_profile.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_model.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/core/settings/vox_margin.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  group('the scale', () {
    test('off is not a point on the dB scale', () {
      // "Off" means nothing is ever withheld, not "the most sensitive gate".
      // Callers ask isOff before they ask for a margin.
      expect(VoxMargin.isOff(VoxMargin.off), isTrue);
      expect(VoxMargin.isOff(-1.0), isTrue);
      expect(VoxMargin.isOff(0.01), isFalse);
      expect(VoxMargin.decibelsFor(VoxMargin.off), 0.0);
      expect(VoxMargin.multiplierFor(VoxMargin.off), 1.0);
    });

    test('the armed range runs from just-above-background to a clear shout', () {
      expect(VoxMargin.decibelsFor(0.001), closeTo(VoxMargin.minDb, 0.1));
      expect(VoxMargin.decibelsFor(1.0), VoxMargin.maxDb);
      expect(VoxMargin.decibelsFor(0.5), closeTo(10.5, 0.001));
    });

    test('more margin is more level, monotonically', () {
      var previous = 0.0;
      for (var m = 0.05; m <= 1.0; m += 0.05) {
        final multiplier = VoxMargin.multiplierFor(m);
        expect(multiplier, greaterThan(previous));
        previous = multiplier;
      }
    });

    test('dB and margin are inverses', () {
      for (final m in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        expect(
          VoxMargin.marginForDecibels(VoxMargin.minDb + 15.0 * m),
          closeTo(m, 1e-9),
        );
      }
    });

    test('the behaviour everyone was running lands mid-slider', () {
      // The fixed 2.5x this replaced. It should sit inside the range with room
      // on both sides, not pinned to an end where half the slider is unusable.
      final legacy = VoxMargin.marginForDecibels(20 * 0.39794); // 2.5x in dB
      expect(legacy, greaterThan(0.15));
      expect(legacy, lessThan(0.6));
    });

    test('out-of-range input is clamped', () {
      expect(VoxMargin.decibelsFor(9.0), VoxMargin.maxDb);
      expect(VoxMargin.marginForDecibels(-100), 0.0);
      expect(VoxMargin.marginForDecibels(100), 1.0);
    });
  });

  group('migrating a stored absolute threshold', () {
    test('the number on the slider does not move', () {
      // The old control ran 0..0.15 and drew itself as 0..100 %. Someone who
      // left it at 60 % opens the app to a slider still reading 60 %; only
      // what it controls changed. We cannot do better — how loud their room
      // was is exactly what the old setting never recorded.
      expect(VoxMargin.fromLegacyThreshold(0.09), closeTo(0.6, 1e-9));
      expect(VoxMargin.fromLegacyThreshold(VoxMargin.legacyMax), 1.0);
    });

    test('off maps to off, exactly', () {
      // An update must never arm a gate the user left disarmed.
      expect(VoxMargin.fromLegacyThreshold(0.0), VoxMargin.off);
      expect(VoxMargin.fromLegacyThreshold(-0.5), VoxMargin.off);
    });

    test('a value past the old full scale does not overshoot', () {
      expect(VoxMargin.fromLegacyThreshold(0.9), 1.0);
    });
  });

  group('reading it back', () {
    test('an install predating the reframe keeps its setting, translated',
        () async {
      final prefs = await prefsWith({SettingsKeys.legacyVoxThreshold: 0.09});
      expect(SettingsModel.readVoxMargin(prefs), closeTo(0.6, 1e-9));
      expect(
        (await SettingsRepositoryImpl(prefs).getVoxMargin()),
        closeTo(0.6, 1e-9),
      );
    });

    test('loadAll and the getter agree about a migrated install', () async {
      // A disagreement here draws one value on the settings page while the
      // engine runs another.
      final prefs = await prefsWith({SettingsKeys.legacyVoxThreshold: 0.03});
      final repo = SettingsRepositoryImpl(prefs);
      expect((await repo.loadAll()).voxMargin, await repo.getVoxMargin());
    });

    test('the new key wins once the slider has been touched', () async {
      final prefs = await prefsWith({
        SettingsKeys.legacyVoxThreshold: 0.15,
        SettingsKeys.voxMargin: 0.2,
      });
      expect(SettingsModel.readVoxMargin(prefs), 0.2);
    });

    test('writing never disturbs the legacy key', () async {
      // Read-through, not rewritten: the old key stays intact, so a downgrade
      // to a build predating the reframe still finds its own setting.
      final prefs = await prefsWith({SettingsKeys.legacyVoxThreshold: 0.06});
      await SettingsRepositoryImpl(prefs).setVoxMargin(0.8);
      expect(prefs.getDouble(SettingsKeys.legacyVoxThreshold), 0.06);
      expect(prefs.getDouble(SettingsKeys.voxMargin), 0.8);
    });

    test('a fresh install gets the default, and the default is off', () async {
      final prefs = await prefsWith({});
      expect(SettingsModel.readVoxMargin(prefs), AppSettings.defaults().voxMargin);
      expect(VoxMargin.isOff(AppSettings.defaults().voxMargin), isTrue);
    });
  });

  group('the riding preset', () {
    test('arms the gate with a real margin now that it can state one', () {
      // The old value was deliberately tiny — its only job was to arm the gate
      // without out-shouting the tracker's fixed 2.5x. A margin cannot
      // out-shout the tracker; it *is* the tracker's setting.
      expect(VoxMargin.isOff(RidingPreset.voxMargin), isFalse);
      expect(
        VoxMargin.decibelsFor(RidingPreset.voxMargin),
        greaterThan(VoxMargin.decibelsFor(0.5) - 1),
      );
    });

    test('asks for more separation than the plain default would', () {
      // Wind gusts move the background between the tracker's updates, and a
      // boom mic inside a helmet clears a wide margin easily.
      expect(RidingPreset.voxMargin, greaterThan(AppSettings.defaults().voxMargin));
    });
  });
}
