// The block table and the codeword stream are the encoder's own, read from
// the package qr_flutter draws with rather than retyped from the spec, so the
// model below cannot drift from what actually ends up on screen.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:qr/qr.dart';
import 'package:qr/src/rs_block.dart';
import 'package:qr/src/util.dart' as qr_util;

/// Where every codeword of a QR symbol physically lands, and so which
/// Reed-Solomon block a centred knock-out would hurt.
///
/// A QR code survives a logo only because each block can repair up to half
/// as many codewords as it carries error-correction codewords. Codewords are
/// interleaved across blocks, so a hole in the middle spreads its damage, but
/// not perfectly evenly — the honest check is per block, for the real layout
/// of the real version, which is what this computes.
final class QrDamageModel {
  QrDamageModel(this.typeNumber, this.errorCorrectLevel)
    : moduleCount = typeNumber * 4 + 17,
      blocks = QrRsBlock.getRSBlocks(typeNumber, errorCorrectLevel) {
    _layOut();
  }

  final int typeNumber;
  final int errorCorrectLevel;
  final int moduleCount;
  final List<QrRsBlock> blocks;

  /// Codeword index (in transmission order) for every module, or -1 for a
  /// function module (finders, timing, alignment, format/version info) and
  /// for the remainder bits that belong to no codeword.
  late final List<List<int>> codewordAt;

  /// Block index for every codeword in transmission order.
  late final List<int> blockOf;

  /// For a square of [knockout] modules centred on the symbol, the worst
  /// block's damage as a share of what that block can correct (errors, not
  /// erasures: a scanner does not know the logo is there). 1.0 means the code
  /// is exactly at the edge of failing with a perfect camera.
  double worstBlockLoad(int knockout) {
    final hit = <int>{};
    final start = (moduleCount - knockout) ~/ 2;
    for (var r = start; r < start + knockout; r += 1) {
      for (var c = start; c < start + knockout; c += 1) {
        final cw = codewordAt[r][c];
        if (cw >= 0) hit.add(cw);
      }
    }
    final perBlock = List<int>.filled(blocks.length, 0);
    for (final cw in hit) {
      perBlock[blockOf[cw]] += 1;
    }
    var worst = 0.0;
    for (var b = 0; b < blocks.length; b += 1) {
      final correctable = (blocks[b].totalCount - blocks[b].dataCount) ~/ 2;
      final load = perBlock[b] / correctable;
      if (load > worst) worst = load;
    }
    return worst;
  }

  /// Function modules, exactly as the encoder reserves them before it places
  /// data.
  List<List<bool>> _functionModules() {
    final n = moduleCount;
    final f = List.generate(n, (_) => List<bool>.filled(n, false));
    void finder(int row, int col) {
      for (var r = -1; r <= 7; r += 1) {
        for (var c = -1; c <= 7; c += 1) {
          final rr = row + r, cc = col + c;
          if (rr >= 0 && rr < n && cc >= 0 && cc < n) f[rr][cc] = true;
        }
      }
    }

    finder(0, 0);
    finder(n - 7, 0);
    finder(0, n - 7);
    final pos = qr_util.patternPosition(typeNumber);
    for (final row in pos) {
      for (final col in pos) {
        if (f[row][col]) continue;
        for (var r = -2; r <= 2; r += 1) {
          for (var c = -2; c <= 2; c += 1) {
            f[row + r][col + c] = true;
          }
        }
      }
    }
    for (var i = 8; i < n - 8; i += 1) {
      f[i][6] = true;
      f[6][i] = true;
    }
    // Format information around the finders, and the fixed dark module.
    for (var i = 0; i < 9; i += 1) {
      f[i][8] = true;
      f[8][i] = true;
    }
    for (var i = 0; i < 8; i += 1) {
      f[n - 1 - i][8] = true;
      f[8][n - 1 - i] = true;
    }
    if (typeNumber >= 7) {
      for (var i = 0; i < 18; i += 1) {
        f[i ~/ 3][i % 3 + n - 11] = true;
        f[i % 3 + n - 11][i ~/ 3] = true;
      }
    }
    return f;
  }

  void _layOut() {
    final n = moduleCount;
    final function = _functionModules();
    codewordAt = List.generate(n, (_) => List<int>.filled(n, -1));
    final total = blocks.fold<int>(0, (sum, b) => sum + b.totalCount);
    // The same zig-zag the encoder's _mapData walks.
    var inc = -1;
    var row = n - 1;
    var bit = 0;
    for (var col = n - 1; col > 0; col -= 2) {
      if (col == 6) col -= 1;
      for (;;) {
        for (var c = 0; c < 2; c += 1) {
          if (!function[row][col - c]) {
            final cw = bit ~/ 8;
            codewordAt[row][col - c] = cw < total ? cw : -1;
            bit += 1;
          }
        }
        row += inc;
        if (row < 0 || row >= n) {
          row -= inc;
          inc = -inc;
          break;
        }
      }
    }
    // The encoder's interleave: data codewords round-robin across blocks,
    // then error-correction codewords the same way.
    final order = <int>[];
    final maxData = blocks.fold<int>(
      0,
      (m, b) => b.dataCount > m ? b.dataCount : m,
    );
    final maxEc = blocks.fold<int>(
      0,
      (m, b) => b.totalCount - b.dataCount > m ? b.totalCount - b.dataCount : m,
    );
    for (var i = 0; i < maxData; i += 1) {
      for (var b = 0; b < blocks.length; b += 1) {
        if (i < blocks[b].dataCount) order.add(b);
      }
    }
    for (var i = 0; i < maxEc; i += 1) {
      for (var b = 0; b < blocks.length; b += 1) {
        if (i < blocks[b].totalCount - blocks[b].dataCount) order.add(b);
      }
    }
    blockOf = order;
  }

  /// Self-check: re-derives every data module of a real encoded symbol from
  /// this layout and the encoder's codeword stream, so a mistake in the model
  /// fails loudly instead of quietly vouching for a broken logo.
  bool reproduces(QrCode code) {
    final image = QrImage(code);
    final stream = code.dataCache;
    for (var r = 0; r < moduleCount; r += 1) {
      for (var c = 0; c < moduleCount; c += 1) {
        final cw = codewordAt[r][c];
        if (cw < 0) continue;
        // Bit position within the codeword follows placement order.
        final bitIndex = _bitIndexAt[r][c];
        var dark = ((stream[cw] >> (7 - bitIndex)) & 1) == 1;
        if (_mask(image.maskPattern, r, c)) dark = !dark;
        if (dark != image.isDark(r, c)) return false;
      }
    }
    return true;
  }

  late final List<List<int>> _bitIndexAt = () {
    final n = moduleCount;
    final out = List.generate(n, (_) => List<int>.filled(n, -1));
    final function = _functionModules();
    var inc = -1;
    var row = n - 1;
    var bit = 0;
    for (var col = n - 1; col > 0; col -= 2) {
      if (col == 6) col -= 1;
      for (;;) {
        for (var c = 0; c < 2; c += 1) {
          if (!function[row][col - c]) {
            out[row][col - c] = bit % 8;
            bit += 1;
          }
        }
        row += inc;
        if (row < 0 || row >= n) {
          row -= inc;
          inc = -inc;
          break;
        }
      }
    }
    return out;
  }();

  static bool _mask(int pattern, int i, int j) => switch (pattern) {
    0 => (i + j).isEven,
    1 => i.isEven,
    2 => j % 3 == 0,
    3 => (i + j) % 3 == 0,
    4 => ((i ~/ 2) + (j ~/ 3)).isEven,
    5 => (i * j) % 2 + (i * j) % 3 == 0,
    6 => ((i * j) % 2 + (i * j) % 3).isEven,
    _ => ((i * j) % 3 + (i + j) % 2).isEven,
  };
}
