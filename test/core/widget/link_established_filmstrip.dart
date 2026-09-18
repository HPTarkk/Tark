// Scratch harness — renders the connect-success sequence to a filmstrip PNG so
// the animation can actually be looked at. Not a test of behaviour; delete
// once the visual is signed off.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/link_established.dart';

const _out = r'C:\Users\pedra\AppData\Local\Temp\claude\D--Dev-wakitaki'
    r'\e09d8d13-3754-481a-abfb-714aac3bbde9\scratchpad\link_established.png';

void main() {
  testWidgets('filmstrip', (tester) async {
    const panel = Size(200, 190);
    // Frames chosen to land one per beat: approach, beam, ring, check, settled.
    const stops = [90, 100, 110, 140, 160, 280];
    final key = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: key,
          child: Container(
            width: panel.width,
            height: panel.height,
            color: const Color(0xFF0B0E11),
            alignment: Alignment.center,
            child: const LinkEstablished(
              label: 'CONNECTED',
              detail: 'Pedram · Bluetooth',
            ),
          ),
        ),
      ),
    );

    final frames = <ui.Image>[];
    for (final step in stops) {
      await tester.pump(Duration(milliseconds: step));
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      frames.add(await boundary.toImage(pixelRatio: 2));
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final w = frames.first.width.toDouble();
    final h = frames.first.height.toDouble();
    for (var i = 0; i < frames.length; i++) {
      canvas.drawImage(frames[i], Offset(w * i, 0), Paint());
    }
    final strip = await recorder.endRecording().toImage(
      (w * frames.length).round(),
      h.round(),
    );
    final bytes = await strip.toByteData(format: ui.ImageByteFormat.png);
    File(_out).writeAsBytesSync(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('wrote $_out');
  });
}
