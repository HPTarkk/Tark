import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import '../utils/logger.dart';
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
  /// Lines held in memory. Sized to cover the last few minutes of a busy
  /// session (the periodic session line, health transitions, socket events)
  /// so an export is useful even where no directory was available.
  static const _ringCapacity = 4000;

  /// How often buffered lines reach the disk. Long enough that a talkative
  /// stretch costs one write, short enough that an OS kill loses seconds
  /// rather than minutes.
  static const _flushInterval = Duration(seconds: 5);

  static const _segmentPrefix = 'tark-';
  static const _segmentSuffix = '.log';

  /// What the log was called before it was a chain of segments: one current
  /// file and one previous. Installs upgrading from that build still have
  /// them on disk, and they are adopted rather than deleted — the log from
  /// just before an update is exactly the log somebody is about to ask for.
  static const _legacyCurrentName = 'tark-current.log';
  static const _legacyPreviousName = 'tark-previous.log';

  /// Written ahead of a line too long to fit a segment on its own. Only
  /// reachable at the very smallest budgets, where a full stack trace can
  /// outweigh an entire segment.
  static const _truncationMark = '  ...[line truncated]\n';

  static final ListQueue<String> _ring = ListQueue<String>(_ringCapacity);
  static final List<String> _pending = <String>[];

  /// Oldest first. The filesystem is the truth, but re-`stat`ing every segment
  /// on every flush would put eight syscalls on a five-second timer for a
  /// number we already know, so sizes are tracked as they're written.
  static final List<_Segment> _segments = <_Segment>[];

  static Directory? _dir;
  static Timer? _flushTimer;
  static bool _enabled = false;
  static String _appVersion = 'unknown';
  static int _maxBytes = LogBudget.defaultBytes;

  /// Serializes everything that touches the segment files.
  ///
  /// Flushing, pruning and clearing all mutate [_segments] across `await`
  /// points, and interleaving any two of them means writing to a file another
  /// task has already unlinked — or, worse, deleting a segment mid-append and
  /// losing the lines that motivated the flush. A queue is enough: a second
  /// flush that lands behind a first finds nothing pending and returns.
  static Future<void> _queue = Future<void>.value();

  /// Session marker, so several sessions in one file can be told apart at a
  /// glance and a "which run was this?" question has an answer.
  static final String sessionId = DateTime.now().millisecondsSinceEpoch
      .toRadixString(36);

  static bool get isEnabled => _enabled;

  /// The ceiling currently in force, in bytes. Always within [LogBudget]'s
  /// range — see [setMaxBytes].
  static int get maxBytes => _maxBytes;

  /// Wires [Logger] to this store and resolves the log directory.
  ///
  /// Safe to call before the directory exists (or on a platform that has
  /// none): lines accumulate in the ring and start reaching disk whenever the
  /// directory turns up. Called from `main()` ahead of everything else worth
  /// logging.
  static Future<void> initialize() async {
    if (_enabled) return;
    _enabled = true;
    Logger.sink = _append;

    // Before any await, so the very first lines of a cold start — which is
    // where a startup failure lives — are already being captured.
    _append('--- session $sessionId opened ${DateTime.now().toIso8601String()}');

    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // A missing package_info is not worth a failed log.
    }
    _append(
      'app: tark $_appVersion on ${_platformName()} '
      '(${Platform.operatingSystemVersion})',
    );

    final path = await DiagnosticsBridge.logsDirectory();
    if (path == null) return;
    try {
      final dir = Directory('$path${Platform.pathSeparator}diagnostics');
      await dir.create(recursive: true);
      _dir = dir;
    } catch (e) {
      // No directory means memory-only logging, which is still better than
      // nothing — an export taken in the same run has the full ring.
      _append('diagnostics: no writable log directory ($e)');
      return;
    }
    // Adopt whatever the last run left behind before the first write, so this
    // session appends to that history instead of starting a parallel chain,
    // and so a ceiling lowered while the app was closed is honoured at once.
    await _serialize(() async {
      await _adoptExisting(_dir!);
      await _enforceBudget();
    });
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
    unawaited(flush());
  }

  /// Moves the ceiling to [bytes] (clamped into [LogBudget]'s range) and
  /// enforces it immediately.
  ///
  /// Lowering it is the interesting direction: the log is over budget the
  /// instant the setting changes, so segments come off the old end right away
  /// rather than at some later flush. The user asked for a smaller log and is
  /// looking at the size readout while they ask.
  static Future<void> setMaxBytes(int bytes) async {
    final next = LogBudget.clamp(bytes);
    if (next == _maxBytes) return;
    _maxBytes = next;
    _append('diagnostics: log ceiling set to ${LogBudget.format(next)}');
    await _serialize(_enforceBudget);
  }

  /// Timestamps a line, rings it, and queues it for the disk.
  ///
  /// Kept synchronous and allocation-light: this runs from [Logger.diagnostic],
  /// which sits on paths that fire every couple of seconds while a channel is
  /// live.
  static void _append(String line) {
    final stamped = '${_timestamp(DateTime.now())} $line';
    if (_ring.length >= _ringCapacity) _ring.removeFirst();
    _ring.add(stamped);
    _pending.add(stamped);
    // A burst (a stack trace, a flood of socket errors) shouldn't wait out the
    // timer — that's exactly the material worth having if the process dies.
    if (_pending.length >= 200) unawaited(flush());
  }

  /// `HH:mm:ss.mmm` — the date is in the session banner and in the export
  /// header, and repeating it on every line triples the file for no gain.
  static String _timestamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${at.millisecond.toString().padLeft(3, '0')}';
  }

  /// Writes everything buffered, rotating and pruning as needed.
  static Future<void> flush() => _serialize(_flushPending);

  static Future<void> _flushPending() async {
    final dir = _dir;
    if (dir == null || _pending.isEmpty) return;
    // Taken before the first await: lines appended while this write is in
    // flight belong to the next flush, not to a list being read underneath it.
    final batch = List<String>.of(_pending);
    _pending.clear();
    try {
      await _writeLines(dir, batch);
    } catch (_) {
      // Disk full, permission revoked, directory deleted underneath us — the
      // ring still holds these lines, so an export is unaffected.
    }
  }

  /// Appends [lines] to the newest segment, starting new ones as it fills.
  ///
  /// Split at line boundaries rather than at the byte the segment happens to
  /// end on: a log whose rotation can cut a timestamp in half is a log you
  /// cannot grep.
  static Future<void> _writeLines(Directory dir, List<String> lines) async {
    final segmentBytes = LogBudget.segmentBytes(_maxBytes);
    final chunk = <int>[];
    for (final line in lines) {
      List<int> encoded = utf8.encode('$line\n');
      // A single line wider than a whole segment would otherwise push that
      // segment over the ceiling with nothing left to prune against it.
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

  /// [encoded] cut to fit [limit], with a marker so the gap is visible rather
  /// than looking like a line that simply ended early.
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
    // Per chunk rather than per flush: a burst big enough to fill the whole
    // ring in one go — a stack trace storm, or a first flush after a long
    // stretch with no writable directory — would otherwise put every one of
    // those segments on disk before anything came off the other end.
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

  /// The sequence number encoded in [name], or null if it isn't a segment.
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

  /// Deletes oldest-first until the log fits the ceiling.
  ///
  /// This is the "overwrite the oldest" contract, and it is the only place
  /// that decides what the log costs on disk.
  static Future<void> _enforceBudget() async {
    if (_dir == null) return;
    while (_segments.length > 1 && _totalBytes > _maxBytes) {
      final oldest = _segments.removeAt(0);
      try {
        if (await oldest.file.exists()) await oldest.file.delete();
      } catch (_) {
        // Already gone, or gone unreadable. Either way it's off the books.
      }
    }
    // One segment can still be over budget on its own — the ceiling was just
    // lowered, and this file was written under the old one. Keep its tail:
    // dropping the whole thing to satisfy a setting would throw away the most
    // recent lines, which is the opposite of what rotation is for.
    if (_segments.length == 1 && _segments.first.bytes > _maxBytes) {
      await _keepTail(_segments.first);
    }
  }

  static int get _totalBytes =>
      _segments.fold<int>(0, (sum, segment) => sum + segment.bytes);

  /// Rewrites [segment] keeping only its last segment's worth of bytes,
  /// starting at a line boundary.
  static Future<void> _keepTail(_Segment segment) async {
    final keep = LogBudget.segmentBytes(_maxBytes);
    try {
      final tail = await _readTail(segment.file, keep);
      if (tail == null) {
        // Already inside the ceiling — our bookkeeping was stale, so take the
        // real length rather than trimming a file that doesn't need it.
        segment.bytes = await segment.file.length();
        return;
      }
      // The read almost certainly landed mid-line; drop that fragment so the
      // file still opens on a timestamp.
      final newline = tail.indexOf(0x0A);
      final body = (newline == -1 || newline + 1 >= tail.length)
          ? tail
          : tail.sublist(newline + 1);
      await segment.file.writeAsBytes(body, flush: false);
      segment.bytes = body.length;
    } catch (_) {
      // Couldn't trim it. The next flush rotates onto a fresh segment and
      // this one becomes prunable in the ordinary way.
    }
  }

  /// The last [keep] bytes of [file], or null when it is already that short.
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

  /// Picks up the segments a previous run left behind, and folds in the two
  /// fixed-name files older builds wrote.
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
      // An unreadable directory just means this run starts a fresh chain.
      return;
    }
    found.sort((a, b) => a.seq.compareTo(b.seq));
    _segments
      ..clear()
      ..addAll(found);
    // Oldest legacy file first, so the pre-upgrade history keeps its order.
    for (final name in const [_legacyPreviousName, _legacyCurrentName]) {
      final file = legacy[name];
      if (file == null) continue;
      try {
        final target = _newSegment(dir);
        final moved = await file.rename(target.file.path);
        _segments.add(_Segment(target.seq, moved, await moved.length()));
      } catch (_) {
        // Leave it where it is; it'll be cleared with everything else.
      }
    }
  }

  /// Everything currently on record, oldest first.
  ///
  /// Flushes first, so the files ARE the whole log by the time they're read and
  /// the ring never has to be merged in (merging two sources that legitimately
  /// overlap is how an export ends up showing its tail twice). The ring is the
  /// fallback for the memory-only case — no writable directory — where there
  /// are no files to read.
  static Future<String> readAll() async {
    await flush();
    final buffer = StringBuffer();
    // Snapshot: reading is not serialized against the flush timer, and a
    // rotation landing mid-read would otherwise mutate the list underneath it.
    for (final segment in List<_Segment>.of(_segments)) {
      try {
        if (!await segment.file.exists()) continue;
        // Lenient decoding on purpose: a process killed mid-write, or a line
        // truncated to fit a small budget, can leave a half-finished UTF-8
        // sequence. One mangled character must not cost the whole export.
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

  /// Packs the log into a `.tarklog` file and returns its path, or null when
  /// there is nothing to export.
  ///
  /// The file is written to the app's own directory under a name that carries
  /// the date, so a user sending two of them a day apart doesn't overwrite the
  /// first in whichever folder the share sheet lands it.
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
      await file.writeAsBytes(
        TarkLogFormat.encode(
          text: text,
          header: {
            'app': 'tark',
            'version': _appVersion,
            'platform': _platformName(),
            'os': Platform.operatingSystemVersion,
            'session': sessionId,
            'exportedAt': now.toIso8601String(),
            'lines': '\n'.allMatches(text).length + 1,
          },
        ),
        flush: true,
      );
      // Previous exports are dead weight the moment a new one is written, and
      // they are the largest thing this feature leaves on the device.
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
      // Best-effort tidying; a leftover export costs a few KB.
    }
  }

  /// Bytes currently on disk, for the Settings row to show what would be sent
  /// and how much of the ceiling is spent.
  ///
  /// Flushes first: the number sits next to a control the user is about to
  /// move, and one that lags five seconds behind reads as a bug.
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

  /// Drops everything — files, the ring, and anything pending — and starts a
  /// fresh session banner so the next line isn't stranded without context.
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
          // Nothing else to try; the next flush starts a new chain.
        }
      }
      _segments.clear();
      // Anything an older build wrote that never got adopted goes too — "clear
      // the log" has to mean the directory, not just the part we track.
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

  /// Runs [task] after every other file-touching task queued before it.
  ///
  /// Failures are swallowed here as well as inside each task: a rejected
  /// write must never poison the chain for every later flush.
  static Future<void> _serialize(Future<void> Function() task) {
    final next = _queue.then((_) => task()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _platformName() => Platform.operatingSystem;

  /// Test seam: points the log at [dir] with [maxBytes] as the ceiling,
  /// bypassing the platform channel that normally resolves the directory.
  /// Not for production use — `main()` calls [initialize].
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

  /// Test seam: unhooks from the filesystem and forgets everything.
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
    });
  }

  /// Test seam: records [line] exactly as [Logger] would, without the `print`
  /// that would otherwise flood a test's output.
  static void debugWrite(String line) => _append(line);

  /// Test seam: the segment file names currently on the books, oldest first.
  static List<String> get debugSegmentNames =>
      _segments.map((s) => _segmentName(s.seq)).toList(growable: false);
}

/// One numbered file in the chain, with the size we last wrote it to.
class _Segment {
  _Segment(this.seq, this.file, this.bytes);

  final int seq;
  final File file;
  int bytes;
}
