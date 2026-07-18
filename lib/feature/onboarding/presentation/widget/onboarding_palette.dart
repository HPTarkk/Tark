import 'package:flutter/material.dart';

/// The onboarding journey renders as one self-contained "field-radio console"
/// world with its own fixed palette, deliberately independent of the app's
/// light/dark theme. The theme the user picks on the tune beat is previewed
/// *environmentally* (the sky arcs day↔night) and only applied to the real app
/// at launch — so the console chrome itself looks identical either way, and
/// every glow/animation is free of the global theme re-key.
abstract final class Onb {
  // Console chrome (mirrors the app's dark "night radio" set so the world
  // feels native even though it never flips).
  static const ink = Color(0xFF0B0E11); // deepest background
  static const panel = Color(0xFF141A21); // glass panel fill
  static const panelHi = Color(0xFF1B222B); // lifted panel edge
  static const line = Color(0xFF2D343D); // hairline borders

  static const amber = Color(0xFFF5853F); // primary accent
  static const amberDim = Color(0xFFD9661F); // secondary accent
  static const green = Color(0xFF49C56A); // on-air / go

  static const text = Color(0xFFE9EDF1);
  static const textDim = Color(0xFF8B939D);

  // ── Sky endpoints, lerped by the 0..1 dayNight value ─────────────────────
  static const dayTop = Color(0xFFAFC0D6); // soft high sky
  static const dayMid = Color(0xFFE7C79E); // warm midband
  static const dayHorizon = Color(0xFFF2A65E); // dawn glow at the ridgeline

  static const nightTop = Color(0xFF080B0F);
  static const nightMid = Color(0xFF0D1218);
  static const nightHorizon = Color(0xFF241A17); // embered dusk band
}
