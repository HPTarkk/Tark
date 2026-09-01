import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the one failure mode a generated file has: being out of date.
///
/// `di_config.config.dart` is checked in, and a build_runner run that ends in
/// an error leaves it exactly as it was. So an annotation the generator chokes
/// on does not fail loudly — it silently freezes the DI graph, and every
/// `@injectable` added afterwards resolves to a `GetIt` that never heard of it.
/// That threw from `initState` on the walkie route and showed a blank screen on
/// every transport, with nothing in the diagnostic log to say why.
///
/// Two questions, both answerable from the text: is every annotated class in
/// the file, and does every lookup in the file have something to find.
void main() {
  final config = File(
    'lib/app/di/di_config.config.dart',
  ).readAsStringSync();

  final registered = RegExp(
    r'gh\.\w+<(?:_i\d+\.)?([A-Za-z0-9_]+)>',
  ).allMatches(config).map((m) => m.group(1)!).toSet();

  test('every injectable class reached the generated config', () {
    final annotation = RegExp(
      r'@(?:injectable|lazySingleton|singleton|LazySingleton|Injectable|Singleton)'
      r'(?:\(\s*as:\s*([A-Za-z0-9_]+))?',
    );
    final declaration = RegExp(
      r'^(?:final |abstract |base |sealed |mixin )*class\s+([A-Za-z0-9_]+)',
    );

    final missing = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('di_config.config.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final declared = declaration.firstMatch(lines[i].trim());
        if (declared == null) continue;
        // Walk back over any annotations stacked above the declaration.
        String? expected;
        for (var j = i - 1; j >= 0; j--) {
          final above = lines[j].trim();
          if (above.isEmpty || above.startsWith('///')) continue;
          if (!above.startsWith('@')) break;
          final match = annotation.firstMatch(above);
          if (match != null) {
            expected = match.group(1) ?? declared.group(1);
            break;
          }
        }
        if (expected == null || registered.contains(expected)) continue;
        missing.add('$expected (${entity.path})');
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'These types are annotated for injection but absent from the '
          'generated config, so GetIt will throw the first time anything asks '
          'for one. Run `dart run build_runner build` and check it exits 0 — '
          'a build that reports an error still leaves the old file in place.',
    );
  });

  test('every lookup in the generated config resolves', () {
    final lookups = RegExp(
      r'gh<(?:_i\d+\.)?([A-Za-z0-9_]+)>\(\)',
    ).allMatches(config).map((m) => m.group(1)!).toSet();

    expect(
      lookups.difference(registered),
      isEmpty,
      reason:
          'The generated config asks GetIt for a type it never registers. The '
          'usual cause is an optional constructor parameter that exists as a '
          'test seam: injectable injects any named parameter whose type it can '
          'name, so mark those `@ignoreParam`.',
    );
  });
}
