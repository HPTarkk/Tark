import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/diagnostic_log.dart';
import 'package:tark/core/diagnostics/log_budget.dart';

/// The promise this feature makes about someone else's storage: the log stops
/// growing at the ceiling, and what it drops to stay there is always the
/// oldest thing it holds.
///
/// These run against a real temp directory rather than a fake filesystem —
/// rotation is rename/unlink behaviour, and a fake that agrees with our
/// assumptions would prove nothing about the phone.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tark-log-test');
  });

  tearDown(() async {
    await DiagnosticLog.debugDetach();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Writes [count] numbered lines, each padded out so the arithmetic in the
  /// expectations is about bytes rather than about how chatty the payload is.
  Future<void> writeLines(int count, {int from = 0}) async {
    for (var i = from; i < from + count; i++) {
      DiagnosticLog.debugWrite('line-$i ${'x' * 60}');
    }
    await DiagnosticLog.flush();
  }

  test('stays under the ceiling however much is written', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.minBytes);
    await writeLines(2000);

    final size = await DiagnosticLog.sizeOnDisk();
    expect(size, greaterThan(0), reason: 'nothing was written at all');
    expect(size, lessThanOrEqualTo(LogBudget.minBytes));
  });

  test('drops the oldest lines and keeps the newest', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.minBytes);
    await writeLines(2000);

    final text = await DiagnosticLog.readAll();
    expect(text, contains('line-1999'), reason: 'the newest line must survive');
    expect(text, isNot(contains('line-0 ')), reason: 'the oldest must not');
  });

  test('keeps the surviving lines in order, oldest first', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.minBytes);
    await writeLines(2000);

    final text = await DiagnosticLog.readAll();
    expect(text.indexOf('line-1998'), lessThan(text.indexOf('line-1999')));
  });

  test('spreads the log over segments rather than one file', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.minBytes);
    await writeLines(2000);

    final names = DiagnosticLog.debugSegmentNames;
    expect(names.length, greaterThan(1));
    expect(names.length, lessThanOrEqualTo(LogBudget.segments));
    // Rotation must not leave orphans behind for the directory to accumulate.
    final onDisk = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.log'))
        .length;
    expect(onDisk, names.length);
  });

  test('lowering the ceiling reclaims the space immediately', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: 1024 * 1024);
    await writeLines(4000);
    final before = await DiagnosticLog.sizeOnDisk();
    expect(before, greaterThan(LogBudget.minBytes));

    await DiagnosticLog.setMaxBytes(LogBudget.minBytes);

    final after = await DiagnosticLog.sizeOnDisk();
    expect(after, lessThanOrEqualTo(LogBudget.minBytes));
    expect(after, lessThan(before));
  });

  test('lowering the ceiling keeps the newest lines, not the oldest', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: 1024 * 1024);
    await writeLines(4000);
    await DiagnosticLog.setMaxBytes(LogBudget.minBytes);

    final text = await DiagnosticLog.readAll();
    expect(text, contains('line-3999'));
    expect(text, isNot(contains('line-0 ')));
  });

  test('a ceiling out of range is clamped, never honoured', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.defaultBytes);

    await DiagnosticLog.setMaxBytes(1 << 40);
    expect(DiagnosticLog.maxBytes, LogBudget.maxBytes);

    await DiagnosticLog.setMaxBytes(1);
    expect(DiagnosticLog.maxBytes, LogBudget.minBytes);
  });

  test('a line wider than a segment is cut, not left to overflow', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.minBytes);
    DiagnosticLog.debugWrite('y' * (LogBudget.minBytes * 2));
    await DiagnosticLog.flush();

    expect(
      await DiagnosticLog.sizeOnDisk(),
      lessThanOrEqualTo(LogBudget.minBytes),
    );
    expect(await DiagnosticLog.readAll(), contains('truncated'));
  });

  test('picks up where the previous run left off', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.defaultBytes);
    await writeLines(10);
    await DiagnosticLog.debugDetach();

    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.defaultBytes);
    await writeLines(10, from: 100);

    final text = await DiagnosticLog.readAll();
    expect(text, contains('line-0 '), reason: 'the previous run is history');
    expect(text, contains('line-100 '), reason: 'this run appends to it');
    expect(text.indexOf('line-0 '), lessThan(text.indexOf('line-100 ')));
  });

  test('adopts the two fixed-name files older builds wrote', () async {
    // What an install upgrading from the pre-segment build has on disk.
    await File(
      '${dir.path}${Platform.pathSeparator}tark-previous.log',
    ).writeAsString('older-history\n');
    await File(
      '${dir.path}${Platform.pathSeparator}tark-current.log',
    ).writeAsString('newer-history\n');

    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.defaultBytes);
    final text = await DiagnosticLog.readAll();

    expect(text, contains('older-history'));
    expect(text, contains('newer-history'));
    expect(
      text.indexOf('older-history'),
      lessThan(text.indexOf('newer-history')),
      reason: 'the pre-upgrade log must keep its order',
    );
  });

  test('clearing removes every segment from the directory', () async {
    await DiagnosticLog.debugAttach(dir, maxBytes: LogBudget.minBytes);
    await writeLines(2000);
    expect(await DiagnosticLog.sizeOnDisk(), greaterThan(0));

    await DiagnosticLog.clear();

    final text = await DiagnosticLog.readAll();
    expect(text, isNot(contains('line-1999')));
    expect(text, contains('log cleared'));
  });
}
