import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/walkie/presentation/widget/walkie_header.dart';

void main() {
  test('ride status indicator owns no repeating ticker state', () {
    expect(const SignalIndicator(), isA<StatelessWidget>());
  });

  test('link quality bars remain deterministic for every transport tier', () {
    expect(LinkQualityBars.barsFor(LinkQuality.excellent), 4);
    expect(LinkQualityBars.barsFor(LinkQuality.good), 3);
    expect(LinkQualityBars.barsFor(LinkQuality.weak), 2);
    expect(LinkQualityBars.barsFor(LinkQuality.recovering), 1);
  });
}
