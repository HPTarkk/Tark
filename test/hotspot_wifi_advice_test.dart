import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';

/// When the "switch Wi-Fi off" note is allowed to speak.
///
/// Getting this wrong in either direction is expensive: a note that never
/// appears leaves riders losing hotspots for a reason their phone knew in
/// advance, and one that appears when it shouldn't trains them to ignore the
/// one time it matters.
void main() {
  HotspotWifiAdvice advice({
    required bool wifiEnabled,
    required bool concurrent,
    bool canPanel = true,
  }) => HotspotWifiAdvice(
    wifiEnabled: wifiEnabled,
    concurrent: concurrent,
    canPanel: canPanel,
  );

  test('speaks only when Wi-Fi is on AND the radio cannot do both', () {
    expect(
      advice(wifiEnabled: true, concurrent: false).shouldSuggestWifiOff,
      isTrue,
    );
  });

  test('stays quiet when Wi-Fi is already off', () {
    // Nothing to ask for — this is the state the note is trying to reach.
    expect(
      advice(wifiEnabled: false, concurrent: false).shouldSuggestWifiOff,
      isFalse,
    );
  });

  test('stays quiet on a phone that can hold both at once', () {
    // STA+AP concurrency means the premise is simply false on this hardware,
    // and asking anyway would be asking for nothing.
    expect(
      advice(wifiEnabled: true, concurrent: true).shouldSuggestWifiOff,
      isFalse,
    );
  });

  test('the silent default is genuinely silent', () {
    // Every non-Android platform and every failed channel read lands here, so
    // it must not be capable of producing a warning. A note raised because a
    // method channel was missing would be pure noise.
    expect(HotspotWifiAdvice.none.shouldSuggestWifiOff, isFalse);
  });

  test('panel availability never gates the advice', () {
    // Whether the toggle opens in a floating panel or the full settings screen
    // changes how the button behaves, not whether the problem exists. An older
    // phone is if anything MORE likely to be single-radio.
    expect(
      advice(
        wifiEnabled: true,
        concurrent: false,
        canPanel: false,
      ).shouldSuggestWifiOff,
      isTrue,
    );
  });
}
