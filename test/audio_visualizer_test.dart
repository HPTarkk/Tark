import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/presentation/widget/audio_visualizer.dart';

/// 20 ms of 16 kHz tone at [amplitude] — the shape the engine emits.
List<double> _frame(double amplitude, {int seed = 0}) => List<double>.generate(
  320,
  (i) => amplitude * sin(2 * pi * 200 * (i + seed * 320) / 16000),
);

Widget _host(List<double> samples, {int barCount = 48}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      width: 200,
      height: 200,
      child: AudioVisualizer(
        samples: samples,
        rms: 0,
        barCount: barCount,
        color: const Color(0xFFFFFFFF),
      ),
    ),
  ),
);

/// Matches the dial if any bar reaches further than [length] logical pixels.
///
/// The painter's geometry is private, so the bars are inspected as what they
/// actually are on the canvas: round-capped lines radiating from the hub.
PaintPattern _drawsBarLongerThan(double length) => paints
  ..something((Symbol method, List<dynamic> arguments) {
    if (method != #drawLine) return false;
    final a = arguments[0] as Offset;
    final b = arguments[1] as Offset;
    return (b - a).distance > length;
  });

Finder get _dial => find.byType(CustomPaint).last;

/// Feeds [count] frames at the widget's cadence, one per pumped frame.
Future<void> _feed(
  WidgetTester tester,
  double amplitude, {
  int count = 40,
  int barCount = 48,
}) async {
  for (var i = 0; i < count; i++) {
    await tester.pumpWidget(_host(_frame(amplitude, seed: i), barCount: barCount));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  // A 200x200 dial has a ~44 px band between hub and rim; idle bars are the
  // floor plus a shimmer of a couple of pixels.
  const idleCeiling = 6.0;
  const halfBand = 22.0;

  testWidgets('speech-level audio swings the bars across the band', (
    tester,
  ) async {
    await _feed(tester, 0.0);
    expect(_dial, isNot(_drawsBarLongerThan(idleCeiling)));

    // Ordinary speech peaks well below full scale; the auto-gain is what has
    // to turn that into a visible swing, so this is the case that matters.
    await _feed(tester, 0.12);
    expect(_dial, _drawsBarLongerThan(halfBand));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the ring falls back to idle when frames stop arriving', (
    tester,
  ) async {
    await _feed(tester, 0.3);
    expect(_dial, _drawsBarLongerThan(halfBand));

    // Same widget, same (now stale) samples: the stream has stalled.
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(_dial, isNot(_drawsBarLongerThan(idleCeiling)));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing barCount mid-flight neither throws nor blanks', (
    tester,
  ) async {
    await _feed(tester, 0.3, count: 15);
    await _feed(tester, 0.3, count: 15, barCount: 24);

    expect(tester.takeException(), isNull);
    expect(_dial, _drawsBarLongerThan(halfBand));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
