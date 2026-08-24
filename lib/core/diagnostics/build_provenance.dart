import 'package:package_info_plus/package_info_plus.dart';

/// Exact build identity carried into diagnostics and field-test evidence.
///
/// The semantic version is useful to a rider; the commit is useful to an
/// engineer. They deliberately stay separate because several commits can
/// share one version while beta work is moving quickly.
///
/// CI/release tooling supplies the compile-time values with `--dart-define`:
///
/// - `GIT_COMMIT` — full source commit SHA;
/// - `GIT_DIRTY` — `true`/`false` when the builder can determine it;
/// - `BUILD_CHANNEL` — e.g. `ci`, `beta`, `local`;
/// - `BUILD_TIMESTAMP` — UTC ISO-8601 build time.
///
/// Missing values remain explicit `unknown` rather than being guessed from a
/// version string. That makes an untraceable build visible instead of silently
/// pretending provenance exists.
class BuildProvenance {
  const BuildProvenance({
    required this.version,
    required this.commit,
    required this.channel,
    required this.buildTimestamp,
    required this.dirty,
  });

  static const _commit = String.fromEnvironment(
    'GIT_COMMIT',
    defaultValue: 'unknown',
  );
  static const _dirty = String.fromEnvironment('GIT_DIRTY');
  static const _channel = String.fromEnvironment(
    'BUILD_CHANNEL',
    defaultValue: 'local',
  );
  static const _timestamp = String.fromEnvironment(
    'BUILD_TIMESTAMP',
    defaultValue: 'unknown',
  );

  final String version;
  final String commit;
  final String channel;
  final String buildTimestamp;
  final bool? dirty;

  static Future<BuildProvenance> resolve() async {
    var version = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Provenance is diagnostic-only. A platform-info failure must never
      // prevent startup or log export.
    }
    return BuildProvenance.fromValues(
      version: version,
      commit: _commit,
      channel: _channel,
      buildTimestamp: _timestamp,
      dirty: parseDirty(_dirty),
    );
  }

  factory BuildProvenance.fromValues({
    required String version,
    required String commit,
    required String channel,
    required String buildTimestamp,
    required bool? dirty,
  }) => BuildProvenance(
    version: _clean(version),
    commit: _clean(commit).toLowerCase(),
    channel: _clean(channel),
    buildTimestamp: _clean(buildTimestamp),
    dirty: dirty,
  );

  static bool? parseDirty(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'true' || '1' || 'yes' || 'dirty' => true,
      'false' || '0' || 'no' || 'clean' => false,
      _ => null,
    };
  }

  static String _clean(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'unknown' : trimmed;
  }

  String get shortCommit =>
      commit.length > 12 ? commit.substring(0, 12) : commit;

  bool get hasExactCommit =>
      RegExp(r'^[0-9a-f]{40}$').hasMatch(commit.toLowerCase());

  String get dirtyLabel => switch (dirty) {
    true => 'dirty',
    false => 'clean',
    null => 'unknown',
  };

  /// One bounded, grep-friendly line for the on-device session header.
  String get diagnosticLine =>
      'build: version=$version commit=$commit dirty=$dirtyLabel '
      'channel=$channel builtAt=$buildTimestamp';

  /// Structured export/header representation. No device/user/network fields
  /// are included here, and no room or transport secret can enter this map.
  Map<String, Object?> toJson() => {
    'version': version,
    'commit': commit,
    'dirty': dirtyLabel,
    'channel': channel,
    'builtAt': buildTimestamp,
  };
}
