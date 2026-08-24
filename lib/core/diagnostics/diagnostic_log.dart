import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../utils/logger.dart';
import 'build_provenance.dart';
import 'diagnostics_bridge.dart';
import 'log_budget.dart';
import 'tark_log_format.dart';

/// On-device diagnostic log: everything [Logger] emits, kept in a rotating
/// file the user can hand back to us.
///
/// ## Why this exists
///
/// The failures worth chasing in this app — a hotspot link that goes one-way
/// after a screen-off cycle, an AP the OS tore down, a mic that opened and
/// delivered nothing — happen on someone else's phone, in a signed release
/// build, minutes into a ride. `adb logcat` reaches none of that. Without a
/// log that survives on the device, every report is "it stopped working" and
/// every diagnosis is a guess.
///
/// ## Shape of it
///
/// * Lines go into an in-memory ring first, so an export always has the tail
///   even if the disk write hasn't happened yet — and so the whole thing keeps
///   working before (or without) a writable directory.
/// * The ring is flushed to disk on a timer, on lifecycle changes, and before
///   any export. Per-line writes would put file I/O on paths that run at
///   presence-tick rate.
/// * On disk the log is a chain of numbered segments, each a fraction of the
///   user's chosen ceiling (see [LogBudget]). Writing appends to the newest;
///   going over budget deletes the oldest. That is the whole growth story —
///   this directory cannot get bigger than what Settings says.
///
/// ## Why segments rather than one file
///
/// A single file that has to stay under a ceiling can only be capped by
/// rewriting it — copying megabytes on a timer to shave the head off. Whole
/// files can just be unlinked. Eight of them means "make room" costs the
/// oldest eighth of the history instead of the oldest half, so a session that
/// just went wrong is never the part that got thrown away.
///
/// Nothing here may throw into a caller: a diagnostic system that can break a
/// call is worse than no diagnostic system.
abstract final class DiagnosticLog {
  static const _ringCapacity = 4000;
  static const _flushInterval = Duration(seconds: 5);
  static const _segmentPrefix = 'tark-';
  static const _segmentSuffix = '.log';
  static const _legacyCurrentName = 'tark-current.log';
  static const _legacyPreviousName = 'tark-previous.log';
  static const _truncationMark = '  ...[line truncated]\n';

  static final ListQueue<String> _ring = ListQueue<String>(_ringCapacity);
  static final List<String> _pending = <String>[];
  static final List<_Segment> _segments = <_Segment>[];

  static Directory? _dir;
  static Timer? _flushTimer;
  static bool _enabled = false;
  static String _appVersion = 'unknown';
  static BuildProvenance? _buildProvenance;
  static int _maxBytes = LogBudget.defaultBytes;
  static Future<void> _queue = Future<void>.value();

  static final String sessionId = DateTime.now().millisecondsSinceEpoch
      .toRadixString(36);

  static bool get isEnabled => _enabled;
  static bool get isPersisting => _dir != null;
  static int get maxBytes => _maxBytes;

  static Future<void> initialize() async {
    if (_enabled) return;
    _enabled = true;
    Logger.sink = _append;

    _append('--- session $sessionId opened ${DateTime.now().toIso8601String()}');

    try {
      final build = await BuildProvenance.resolve();
      _buildProvenance = build;
      _appVersion = build.version;
      _append(
        'app: tark $_appVersion on ${_platformName()} '
        '(${Platform.operatingSystemVersion})',
      );
      _append(build.diagnosticLine);
    } catch (_) {
      // Build identity is diagnostic-only. Keep startup and export available
      // even if the platform package-info channel is unavailable.
      _append(
        'app: tark $_appVersion on ${_platformName()} '
        '(${Platform.operatingSystemVersion})',
      );
      _append(
        'build: version=unknown commit=unknown dirty=unknown '
        'channel=unknown builtAt=unknown',
      );
    }

    final path = await DiagnosticsBridge.logsDirectory();
    if (path == null) return;
    try {
      final dir = Directory('$path${Platform.pathSeparator}diagnostics');
      await dir.create(recursive: true);
      _dir = dir;
    } catch (e) {
      _append('diagnostics: no writable log directory ($e)');
      return;
    }
    await _serialize(() async {
      await _adoptExisting(_dir!);
      await _enforceBudget();
    });
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
    unawaited(flush());
  }

  static Future<void> setMaxBytes(int bytes) async {
    final next = LogBudget.clamp(bytes);
    if (next == _maxBytes) return;
    _maxBytes = next;
    _append('diagnostics: log ceiling set to ${LogBudget.format(next)}');
    await _serialize(_enforceBudget);
  }

  static void _append(String line) {
    final stamped = '${_timestamp(DateTime.now())} $line';
    if (_ring.length >= _ringCapacity) _ring.removeFirst();
    _ring.add(stamped);
    _pending.add(stamped);
    if (_pending.length >= 200) unawaited(flush());
  }

  static String _timestamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${at.millisecond.toString().padLeft(3, '0')}';
  }

  static Future<void> flush() => _serialize(_flushPending);

  static Future<void> _flushPending() async {
    final dir = _dir;
    if (dir == null || _pending.isEmpty) return;
    final batch = List<String>.of(_pending);
    _pending.clear();
    try {
      await _writeLines(dir, batch);
    } catch (_) {
      // Disk failures never escape into the live call path.
    }
  }

  static Future<void> _writeLines(Directory dir, List<String> lines) async {
    final segmentBytes = LogBudget.segmentBytes(_maxBytes);
    final chunk = <int>[];
    for (final line in lines) {
      List<int> encoded = utf8.encode('$line\n');
      if (encoded.length > segmentBytes) {
        encoded = _truncated(encoded, segmentBytes);
      }
      if (chunk.isNotEmpty && chunk.length + encoded.length > segmentBytes) {
        await _appendChunk(dir, chunk, segmentBytes);
        chunk.clear();
      }
      chunk.addAll(encoded);
    }
    if (chunk.isNotEmpty) await _appendChunk(dir, chunk, segmentBytes);
  }

  static List<int> _truncated(List<int> encoded, int limit) {
    final mark = utf8.encode(_truncationMark);
    final keep = limit - mark.length;
    if (keep <= 0) return encoded.sublist(0, limit);
    return <int>[...encoded.sublist(0, keep), ...mark];
  }

  static Future<void> _appendChunk(
    Directory dir,
    List<int> data,
    int segmentBytes,
  ) async {
    var segment = _segments.isEmpty ? null : _segments.last;
    if (segment == null || segment.bytes + data.length > segmentBytes) {
      segment = _newSegment(dir);
      _segments.add(segment);
    }
    await segment.file.writeAsBytes(
      data,
      mode: FileMode.append,
      flush: false,
    );
    segment.bytes += data.length;
    await _enforceBudget();
  }

  static _Segment _newSegment(Directory dir) {
    final seq = _segments.isEmpty ? 0 : _segments.last.seq + 1;
    return _Segment(
      seq,
      File('${dir.path}${Platform.pathSeparator}${_segmentName(seq)}'),
      0,
    );
  }

  static String _segmentName(int seq) =>
      '$_segmentPrefix${seq.toString().padLeft(6, '0')}$_segmentSuffix';

  static int? _sequenceOf(String name) {
    if (!name.startsWith(_segmentPrefix) || !name.endsWith(_segmentSuffix)) {
      return null;
    }
    final digits = name.substring(
      _segmentPrefix.length,
      name.length - _segmentSuffix.length,
    );
    if (digits.isEmpty) return null;
    return int.tryParse(digits);
  }

  static Future<void> _enforceBudget() async {
    if (_dir == null) return;
    while (_segments.length > 1 && _totalBytes > _maxBytes) {
      final oldest = _segments.removeAt(0);
      try {
        if (await oldest.file.exists()) await oldest.file.delete();
      } catch (_) {
        // Already gone, or unreadable.
      }
    }
    if (_segments.length == 1 && _segments.first.bytes > _maxBytes) {
      await _keepTail(_segments.first);
    }
  }

  static int get _totalBytes =>
      _segments.fold<int>(0, (sum, segment) => sum + segment.bytes);

  static Future<void> _keepTail(_Segment segment) async {
    final keep = LogBudget.segmentBytes(_maxBytes);
    try {
      final tail = await _readTail(segment.file, keep);
      if (tail == null) {
        segment.bytes = await segment.file.length();
        return;
      }
      final newline = tail.indexOf(0x0A);
      final body = (newline == -1 || newline + 1 >= tail.length)
          ? tail
          : tail.sublist(newline + 1);
      await segment.file.writeAsBytes(body, flush: false);
      segment.bytes = body.length;
    } catch (_) {
      // The next rotation can prune it normally.
    }
  }

  static Future<List<int>?> _readTail(File file, int keep) async {
    final handle = await file.open();
    try {
      final length = await handle.length();
      if (length <= keep) return null;
      await handle.setPosition(length - keep);
      return await handle.read(keep);
    } finally {
      await handle.close();
    }
  }

  static Future<void> _adoptExisting(Directory dir) async {
    final found = <_Segment>[];
    final legacy = <String, File>{};
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name == _legacyCurrentName || name == _legacyPreviousName) {
          legacy[name] = entity;
          continue;
        }
        final seq = _sequenceOf(name);
        if (seq == null) continue;
        found.add(_Segment(seq, entity, await entity.length()));
      }
    } catch (_) {
      return;
    }
    found.sort((a, b) => a.seq.compareTo(b.seq));
    _segments
      ..clear()
      ..addAll(found);
    for (final name in const [_legacyPreviousName, _legacyCurrentName]) {
      final file = legacy[name];
      if (file == null) continue;
      try {
        final target = _newSegment(dir);
        final moved = await file.rename(target.file.path);
        _segments.add(_Segment(target.seq, moved, await moved.length()));
      } catch (_) {
        // Leave an unmovable legacy file in place.
      }
    }
  }

  static Future<String> readAll() async {
    await flush();
    final buffer = StringBuffer();
    for (final segment in List<_Segment>.of(_segments)) {
      try {
        if (!await segment.file.exists()) continue;
        buffer.write(
          utf8.decode(await segment.file.readAsBytes(), allowMalformed: true),
        );
      } catch (_) {
        buffer.writeln('--- ${_segmentName(segment.seq)} unreadable');
      }
    }
    if (buffer.isEmpty) buffer.writeAll(_ring, '\n');
    return buffer.toString();
  }

  static Future<String?> export() async {
    final text = await readAll();
    if (text.trim().isEmpty) return null;
    final dir = _dir;
    if (dir == null) return null;
    try {
      final now = DateTime.now();
      final stamp =
          '${now.year}${_two(now.month)}${_two(now.day)}'
          '-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'tark-log-$stamp.${TarkLogFormat.extension}',
      );
      final build = _buildProvenance;
      await file.writeAsBytes(
        TarkLogFormat.encode(
          text: text,
          header: {
            'app': 'tark',
            'version': _appVersion,
            'commit': build?.commit ?? 'unknown',
            'dirty': build?.dirtyLabel ?? 'unknown',
            'channel': build?.channel ?? 'unknown',
            'builtAt': build?.buildTimestamp ?? 'unknown',
            'platform': _platformName(),
            'os': Platform.operatingSystemVersion,
            'session': sessionId,
            'exportedAt': now.toIso8601String(),
            'lines': '\n'.allMatches(text).length + 1,
          },
        ),
        flush: true,
      );
      await _pruneOldExports(dir, keep: file.path);
      return file.path;
    } catch (e) {
      Logger.diagnostic('diagnostics: export failed ($e)');
      return null;
    }
  }

  static Future<void> _pruneOldExports(
    Directory dir, {
    required String keep,
  }) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (entity.path == keep) continue;
        if (!entity.path.endsWith('.${TarkLogFormat.extension}')) continue;
        await entity.delete();
      }
    } catch (_) {
      // Best-effort tidying.
    }
  }

  static Future<int> sizeOnDisk() async {
    await flush();
    if (_dir == null) return 0;
    var total = 0;
    for (final segment in List<_Segment>.of(_segments)) {
      try {
        if (await segment.file.exists()) total += await segment.file.length();
      } catch (_) {
        // Skip what can't be measured.
      }
    }
    return total;
  }

  static Future<void> clear() => _serialize(_clearAll);

  static Future<void> _clearAll() async {
    _pending.clear();
    _ring.clear();
    final dir = _dir;
    if (dir != null) {
      for (final segment in _segments) {
        try {
          if (await segment.file.exists()) await segment.file.delete();
        } catch (_) {
          // Nothing else to try.
        }
      }
      _segments.clear();
      for (final name in const [_legacyPreviousName, _legacyCurrentName]) {
        try {
          final file = File('${dir.path}${Platform.pathSeparator}$name');
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Best effort.
        }
      }
    }
    _append('--- log cleared ${DateTime.now().toIso8601String()}');
  }

  static Future<void> _serialize(Future<void> Function() task) {
    final next = _queue.then((_) => task()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
  static String _platformName() => Platform.operatingSystem;

  static Future<void> debugAttach(
    Directory dir, {
    required int maxBytes,
  }) async {
    _enabled = true;
    Logger.sink = _append;
    _maxBytes = LogBudget.clamp(maxBytes);
    _dir = dir;
    _pending.clear();
    _ring.clear();
    _segments.clear();
    await _serialize(() => _adoptExisting(dir));
  }

  static Future<void> debugDetach() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    Logger.sink = null;
    await _serialize(() async {
      _dir = null;
      _enabled = false;
      _segments.clear();
      _pending.clear();
      _ring.clear();
      _maxBytes = LogBudget.defaultBytes;
      _buildProvenance = null;
      _appVersion = 'unknown';
    });
  }

  static void debugWrite(String line) => _append(line);

  static List<String> get debugSegmentNames =>
      _segments.map((s) => _segmentName(s.seq)).toList(growable: false);
}

class _Segment {
  _Segment(this.seq, this.file, this.bytes);

  final int seq;
  final File file;
  int bytes;
}
