import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:qr_flutter/qr_flutter.dart';

/// How a branded Tarkk QR code is built so the centre mark never costs a scan.
///
/// The mark is stamped over the middle of the code, which destroys the
/// codewords underneath it. A QR code survives that only through its
/// Reed-Solomon error correction, and only up to each block's budget — so
/// every decision here is about staying well inside that budget while keeping
/// the modules big enough for a camera pointed at another phone's screen:
///
/// * **Error-correction level.** Q (recovers ~25%) by default. A long invite at
///   Q needs so many modules that each one gets small, so when Q's modules
///   would be cramped at the size the card is drawn, M (~15%) is used instead
///   — with a mark sized for M's smaller budget. Never L: L's ~7% has no room
///   for a mark on top of glare, blur and a moiré'd screen.
/// * **Mark size, per version.** The knock-out is an odd number of modules
///   wide, centred exactly on the module grid, and is the largest square whose
///   damage stays within **half** of what the worst-hit block can correct.
///   That leaves the other half for the camera. The damage is not uniform
///   across versions — interleaving lands a centred hole on some blocks harder
///   than others — so the size comes from [_safeMarkQ] / [_safeMarkM], which
///   were computed from the encoder's real module placement and block table
///   for every version and are re-proved by
///   `test/core/widget/qr_brand_plan_test.dart`.
/// * **A minimum mark.** If a version's safe square would be too small to read
///   as the logo, the next version up is used instead: a few more modules is a
///   better trade than a smudge.
/// * **Module pitch and quiet zone.** The plan, not qr_flutter, decides how
///   big a module is: qr_flutter rounds the pitch to a half pixel and can round
///   *up*, which on a dense code pushes it into its own quiet zone, and rounds
///   a 1.8 px module *down* to 1.5 px. The card draws the code at exactly
///   [modulePitch], with at least [quietModules] of white around it.
final class QrBrandPlan {
  const QrBrandPlan._({
    required this.errorCorrectLevel,
    required this.version,
    required this.markModules,
  });

  /// Builds the plan for [data] drawn in a square of [size] logical pixels.
  factory QrBrandPlan.of(String data, {required double size}) {
    final q = _candidate(data, QrErrorCorrectLevel.Q);
    if (q != null && _rawPitch(size, q.moduleCount) >= comfortablePitch) {
      return q;
    }
    final m = _candidate(data, QrErrorCorrectLevel.M);
    if (q == null) {
      // Past what Q can hold at all: M, or — never in practice, the largest
      // Room invite is about half of M's capacity — the bare code.
      return m ?? QrBrandPlan._unbranded(data);
    }
    if (m == null || m.moduleCount >= q.moduleCount) return q;
    return m;
  }

  factory QrBrandPlan._unbranded(String data) {
    final code = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    return QrBrandPlan._(
      errorCorrectLevel: QrErrorCorrectLevel.L,
      version: code.typeNumber,
      markModules: 0,
    );
  }

  /// Error-correction level to encode at (a [QrErrorCorrectLevel] value).
  final int errorCorrectLevel;

  /// QR version (1–40) to encode at. Can be above the smallest that fits the
  /// data, when that buys a mark big enough to read.
  final int version;

  /// Width of the centred knock-out, in modules. Odd, so it lines up with the
  /// grid; 0 only for a payload too long to brand at all.
  final int markModules;

  int get moduleCount => version * 4 + 17;

  bool get branded => markModules > 0;

  /// Below this a module is hard to resolve from another phone's screen. The
  /// v1 Room invite was drawn at 1.5 px modules and was reported from the
  /// field as hard to scan.
  static const double minModulePitch = 2;

  /// At or above this Q's modules are roomy enough that its stronger
  /// correction is worth more than M's bigger modules.
  static const double comfortablePitch = 2.5;

  /// The ISO 18004 quiet zone: four modules of white around the code.
  static const int quietModules = 4;

  /// White the card already draws around the code area (its padding), which
  /// counts towards the quiet zone.
  static const double cardMargin = 14;

  /// The mark is never narrower than this share of the code; below it the
  /// logo stops reading as a logo.
  static const double minMarkFraction = 0.19;

  /// Nor wider than this, whatever the budget allows: past it the mark
  /// starts competing with the code for attention.
  static const double maxMarkFraction = 0.24;

  /// Side of a module, in logical pixels, when the code area is a square of
  /// [size]: qr_flutter's usual inset, unless the quiet zone needs more.
  double modulePitch(double size) {
    final n = moduleCount;
    final pitch = _rawPitch(size, n);
    // The quiet zone is 4 modules, of which the card's own margin pays part:
    // where the usual inset falls short, solve
    // cardMargin + (size - pitch·n) / 2 = quietModules·pitch.
    if (cardMargin + (size - pitch * n) / 2 >= quietModules * pitch) {
      return pitch;
    }
    return (size + 2 * cardMargin) / (n + 2 * quietModules);
  }

  /// Side of the drawn code itself, without its quiet zone.
  double codeExtent(double size) => modulePitch(size) * moduleCount;

  /// Side of the mark's knock-out.
  double markExtent(double size) => modulePitch(size) * markModules;

  /// White around the code on each side, the card's margin included, in
  /// modules.
  double quietZoneModules(double size) =>
      (cardMargin + (size - codeExtent(size)) / 2) / modulePitch(size);

  /// The size to draw [data] at: [preferred], grown towards [max] until the
  /// modules reach [minModulePitch]. A dense code gets a bigger card instead
  /// of smaller squares.
  static double sizeFor(
    String data, {
    required double preferred,
    required double max,
  }) {
    if (max <= preferred) return preferred;
    final plan = QrBrandPlan.of(data, size: preferred);
    if (plan.modulePitch(preferred) >= minModulePitch) return preferred;
    final needed = plan.moduleCount * minModulePitch + 2 * _inset;
    final grown = math.min(max, needed);
    // Growing can tip the level choice; keep the bigger card only if it
    // really buys a bigger module.
    final regrown = QrBrandPlan.of(data, size: grown);
    return regrown.modulePitch(grown) > plan.modulePitch(preferred)
        ? grown
        : preferred;
  }

  /// The inset qr_flutter draws a code with by default, kept so a plan's
  /// codes sit where they always have.
  static const double _inset = 10;

  static double _rawPitch(double size, int moduleCount) =>
      (size - 2 * _inset) / moduleCount;

  static QrBrandPlan? _candidate(String data, int level) {
    if (utf8.encode(data).length > _byteCapacityAt40[level]!) return null;
    // fromData stops at version 40 without checking the data fits there; the
    // line above is that check.
    final code = QrCode.fromData(data: data, errorCorrectLevel: level);
    final table = level == QrErrorCorrectLevel.Q ? _safeMarkQ : _safeMarkM;
    for (var version = code.typeNumber; version <= 40; version += 1) {
      final n = version * 4 + 17;
      final mark = math.min(table[version - 1], _oddFloor(maxMarkFraction * n));
      if (mark / n >= minMarkFraction) {
        return QrBrandPlan._(
          errorCorrectLevel: level,
          version: version,
          markModules: mark,
        );
      }
    }
    return null;
  }

  static int _oddFloor(double value) {
    final floor = value.floor();
    return floor.isOdd ? floor : floor - 1;
  }

  /// Byte-mode capacity of a version-40 code (ISO 18004, table 7).
  static const Map<int, int> _byteCapacityAt40 = {
    QrErrorCorrectLevel.M: 2331,
    QrErrorCorrectLevel.Q: 1663,
  };

  /// Largest centred knock-out, in modules, per version (index 0 = version 1),
  /// whose damage stays within half of every Reed-Solomon block's correction
  /// capacity at level Q. Generated from the encoder's own layout; proved
  /// again in `test/core/widget/qr_brand_plan_test.dart`.
  static const List<int> _safeMarkQ = [
    3, 3, 5, 7, 9, 9, 11, 11, 13, 13, //
    15, 15, 17, 17, 19, 19, 21, 21, 21, 23, //
    21, 21, 23, 27, 27, 29, 27, 31, 33, 33, //
    35, 35, 37, 37, 39, 39, 41, 41, 37, 43, //
  ];

  /// The same for level M.
  static const List<int> _safeMarkM = [
    3, 3, 3, 5, 7, 7, 7, 9, 9, 13, //
    15, 11, 15, 11, 15, 13, 21, 19, 21, 23, //
    23, 25, 25, 27, 27, 27, 29, 25, 31, 29, //
    27, 33, 29, 21, 27, 21, 27, 35, 41, 43, //
  ];

  /// Exposed for the test that re-derives them.
  @visibleForTesting
  static List<int> safeMarkTable(int level) =>
      level == QrErrorCorrectLevel.Q ? _safeMarkQ : _safeMarkM;
}
