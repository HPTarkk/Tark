import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'log_detail.dart';
import 'screen_log.dart';

/// Logs every tap in the app at [LogDetail.everything], naming what was
/// tapped as well as it can: the text on it, its key, and the kind of
/// control.
///
///     ui: touch "Start channel" [landing-create-room] (InkWell) on LandingPage
///
/// Wraps the whole app once (see MyApp). It only listens — it never claims a
/// gesture, so nothing underneath behaves differently — and it does no work
/// at all below [LogDetail.everything]. When it is on, the one walk of the
/// widget tree happens on finger up, never per frame.
class TapLog extends StatefulWidget {
  const TapLog({required this.child, super.key});

  final Widget child;

  /// A finger that moved further than this was a scroll or a drag, not a tap.
  static const _slop = kTouchSlop;

  @override
  State<TapLog> createState() => _TapLogState();

  /// Describes what sits under [globalPosition] in [root]'s subtree.
  @visibleForTesting
  static String describeAt(Element root, Offset globalPosition) {
    final path = _hitPath(root, globalPosition);
    if (path.isEmpty) return _at(globalPosition);

    // The control the finger landed on: the innermost tappable widget on the
    // path, or the innermost widget when nothing on it is tappable.
    // A named control (a button, a switch, a chip) wins over the raw
    // gesture detectors every one of them is built from, so a TextButton is
    // reported as a TextButton rather than as its inner GestureDetector.
    Element? named;
    Element? raw;
    for (final element in path.reversed) {
      final w = element.widget;
      if (named == null && _isNamedControl(w)) named = element;
      if (raw == null && (w is InkResponse || w is GestureDetector)) {
        raw = element;
      }
    }
    final target = named ?? raw ?? path.last;

    final label = _labelIn(target);
    String? key;
    for (final element in path.sublist(0, path.indexOf(target) + 1).reversed) {
      final k = element.widget.key;
      if (k is ValueKey<String>) {
        key = k.value;
        break;
      }
    }

    final parts = [
      if (label != null) '"$label"',
      if (key != null) '[$key]',
      '(${target.widget.runtimeType})',
    ];
    if (label == null && key == null) parts.add(_at(globalPosition));
    return parts.join(' ');
  }

  static String _at(Offset p) =>
      'at ${p.dx.toStringAsFixed(0)},${p.dy.toStringAsFixed(0)}';

  /// The chain of elements, outermost first, whose boxes contain the point.
  /// Where several siblings contain it (a Stack, the Overlay's routes) the
  /// last one wins, because it is the one painted on top.
  static List<Element> _hitPath(Element root, Offset global) {
    // A box counts as hit when it contains the point. Anything else (a
    // widget with no box of its own, a sliver) counts only through a hit
    // descendant, so an empty slot never outbids the button beneath it.
    List<Element>? visit(Element element) {
      final ro = element is RenderObjectElement ? element.renderObject : null;
      final isBox = ro is RenderBox;
      if (isBox) {
        if (!ro.attached || !ro.hasSize) return null;
        final local = ro.globalToLocal(global);
        if (!(Offset.zero & ro.size).contains(local)) return null;
      }
      List<Element>? best;
      element.visitChildElements((child) {
        final path = visit(child);
        if (path != null) best = path;
      });
      if (best == null && !isBox) return null;
      return [element, ...?best];
    }

    return visit(root) ?? const [];
  }

  static bool _isNamedControl(Widget w) =>
      w is ButtonStyleButton ||
      w is RawChip ||
      w is ChoiceChip ||
      w is FilterChip ||
      w is IconButton ||
      w is ListTile ||
      w is Switch ||
      w is Checkbox ||
      w is Radio ||
      w is Slider ||
      w is PopupMenuButton ||
      w is TextField;

  /// The first readable text inside [element]: a Text, a RichText, a
  /// tooltip or a semantics label.
  static String? _labelIn(Element element) {
    String? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      final text = switch (w) {
        Text(:final data?) => data,
        Text(:final textSpan?) => textSpan.toPlainText(),
        RichText(:final text) => text.toPlainText(),
        Tooltip(:final message?) => message,
        Semantics(:final properties) => properties.label,
        _ => null,
      };
      if (text != null && text.trim().isNotEmpty) {
        found = text.trim().replaceAll(RegExp(r'\s+'), ' ');
        return;
      }
      e.visitChildElements(visit);
    }

    visit(element);
    final label = found;
    if (label == null) return null;
    return label.length > 60 ? '${label.substring(0, 60)}…' : label;
  }
}

class _TapLogState extends State<TapLog> {
  final Map<int, Offset> _downAt = {};

  void _onDown(PointerDownEvent e) {
    if (!ScreenLog.logsEverything) return;
    _downAt[e.pointer] = e.position;
  }

  void _onUp(PointerUpEvent e) {
    final down = _downAt.remove(e.pointer);
    if (down == null || !ScreenLog.logsEverything) return;
    if ((e.position - down).distance > TapLog._slop) return;
    ScreenLog.anyTap(TapLog.describeAt(context as Element, e.position));
  }

  void _onCancel(PointerCancelEvent e) => _downAt.remove(e.pointer);

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerUp: _onUp,
    onPointerCancel: _onCancel,
    child: widget.child,
  );
}
