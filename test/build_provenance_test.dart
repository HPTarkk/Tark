import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/build_provenance.dart';

void main() {
  group('BuildProvenance', () {
    test('normalizes fields and exposes a short commit', () {
      final build = BuildProvenance.fromValues(
        version: ' 1.2.3+45 ',
        commit: 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
        channel: ' beta ',
        buildTimestamp: ' 2026-08-24T04:00:00Z ',
        dirty: false,
      );

      expect(build.version, '1.2.3+45');
      expect(build.commit, 'abcdef0123456789abcdef0123456789abcdef01');
      expect(build.shortCommit, 'abcdef012345');
      expect(build.channel, 'beta');
      expect(build.dirtyLabel, 'clean');
      expect(build.hasExactCommit, isTrue);
    });

    test('keeps missing provenance explicit instead of guessing', () {
      final build = BuildProvenance.fromValues(
        version: '',
        commit: '',
        channel: '',
        buildTimestamp: '',
        dirty: null,
      );

      expect(build.version, 'unknown');
      expect(build.commit, 'unknown');
      expect(build.channel, 'unknown');
      expect(build.buildTimestamp, 'unknown');
      expect(build.dirtyLabel, 'unknown');
      expect(build.hasExactCommit, isFalse);
    });

    test('parses dirty-state aliases', () {
      expect(BuildProvenance.parseDirty('true'), isTrue);
      expect(BuildProvenance.parseDirty('dirty'), isTrue);
      expect(BuildProvenance.parseDirty('0'), isFalse);
      expect(BuildProvenance.parseDirty('clean'), isFalse);
      expect(BuildProvenance.parseDirty(''), isNull);
      expect(BuildProvenance.parseDirty('maybe'), isNull);
    });

    test('diagnostic and structured forms contain no unrelated identifiers', () {
      final build = BuildProvenance.fromValues(
        version: '1.2.3+45',
        commit: 'abcdef0123456789abcdef0123456789abcdef01',
        channel: 'beta',
        buildTimestamp: '2026-08-24T04:00:00Z',
        dirty: true,
      );

      expect(
        build.diagnosticLine,
        'build: version=1.2.3+45 '
        'commit=abcdef0123456789abcdef0123456789abcdef01 '
        'dirty=dirty channel=beta builtAt=2026-08-24T04:00:00Z',
      );
      expect(build.toJson(), {
        'version': '1.2.3+45',
        'commit': 'abcdef0123456789abcdef0123456789abcdef01',
        'dirty': 'dirty',
        'channel': 'beta',
        'builtAt': '2026-08-24T04:00:00Z',
      });
    });
  });
}
