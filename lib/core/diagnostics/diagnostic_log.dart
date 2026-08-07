import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import '../utils/logger.dart';
import 'diagnostics_bridge.dart';
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
/// * Two files, rotated at [_maxFileBytes], so the log is bounded but a
///   session that just went wrong is never the half that got thrown away.
///
/// Nothing here may throw into a caller: a diagnostic system that can break a
/// call is worse than no diagnostic system.
abstract final class DiagnosticLog {
  /// Lines held in memory. Sized to cover the last few minutes of a busy
  /// session (the periodic session line, health transitions, socket events)
  /// so an export is useful even where no directory was available.
  static const _ringCapacity = 4000;

  /// Rotate at this size. Two of these is the whole on-disk budget: small
  /// enough to attach to a chat message after compression, long enough to hold
  /// a session that ran for an hour.
  static const _maxFileBytes = 512 * 1024;

  /// How often buffered lines reach the disk. Long enough that a talkative
  /// stretch costs one write, short enough that an OS kill loses seconds
  /// rather than minutes.
  static const _flushInterval = Duration(seconds: 5);

  static const _currentName = 'tark-current.log';
  static const _previousName = 'tark-previous.log';

  static final ListQueue<String> _ring = ListQueue<String>(_ringCapacity);
  static final List<String> _pending = <String>[];

  static Directory? _dir;
  static Timer? _flushTimer;
  static bool _enabled = false;
  static bool _flushing = false;
  static String _appVersion = 'unknown';

  /// Session marker, so several sessions in one file can be told apart at a
  /// glance and a "which run was this?" question has an answer.
  static final String sessionId = DateTime.now().millisecondsSinceEpoch
      .toRadixString(36);

  static bool get isEnabled => _enabled;

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
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
    unawaited(flush());
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

  /// Writes everything buffered, rotating first if the current file is full.
  ///
  /// Re-entrancy guarded rather than queued: a flush that overlaps another
  /// would interleave lines in the file, and the second one has nothing to do
  /// that the first isn't already doing.
  static Future<void> flush() async {
    final dir = _dir;
    if (dir == null || _flushing || _pending.isEmpty) return;
    _flushing = true;
    // Taken before the first await: lines appended while this write is in
    // flight belong to the next flush, not to a list being read underneath it.
    final batch = _pending.join('\n');
    _pending.clear();
    try {
      final current = File('${dir.path}${Platform.pathSeparator}$_currentName');
      if (await current.exists() && await current.length() > _maxFileBytes) {
        final previous = File(
          '${dir.path}${Platform.pathSeparator}$_previousName',
        );
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      }
      await File(
        '${dir.path}${Platform.pathSeparator}$_currentName',
      ).writeAsString('$batch\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Disk full, permission revoked, directory deleted underneath us — the
      // ring still holds these lines, so an export is unaffected.
    } finally {
      _flushing = false;
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
    final dir = _dir;
    if (dir != null) {
      for (final name in const [_previousName, _currentName]) {
        try {
          final file = File('${dir.path}${Platform.pathSeparator}$name');
          if (await file.exists()) buffer.write(await file.readAsString());
        } catch (_) {
          buffer.writeln('--- $name unreadable');
        }
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

  /// Bytes currently on disk, for the Settings row to show what would be sent.
  static Future<int> sizeOnDisk() async {
    final dir = _dir;
    if (dir == null) return 0;
    var total = 0;
    for (final name in const [_previousName, _currentName]) {
      try {
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        if (await file.exists()) total += await file.length();
      } catch (_) {
        // Skip what can't be measured.
      }
    }
    return total;
  }

  /// Drops everything — files, the ring, and anything pending — and starts a
  /// fresh session banner so the next line isn't stranded without context.
  static Future<void> clear() async {
    _pending.clear();
    _ring.clear();
    final dir = _dir;
    if (dir != null) {
      for (final name in const [_previousName, _currentName]) {
        try {
          final file = File('${dir.path}${Platform.pathSeparator}$name');
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Nothing else to try; the next flush recreates the current file.
        }
      }
    }
    _append('--- log cleared ${DateTime.now().toIso8601String()}');
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _platformName() => Platform.operatingSystem;
}
