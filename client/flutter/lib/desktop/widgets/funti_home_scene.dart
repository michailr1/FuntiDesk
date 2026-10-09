// FUNTIDESK: illustration of the home-screen banner.
//
// A person on the road holds a phone with Funtik on its screen; a secure
// link runs to the webcam of the home computer, next to which Funtik sits.
// The drawing is the approved mockup (docs/reviews/2026-10-07-handoff.md,
// section 4) split into SVG layers on one 760x210 canvas, so that the tail,
// the eyes and the dots on the link can be animated separately. With system
// animations turned off the scene stays still.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../common/funti_theme.dart';

const double _kSceneWidth = 760;
const double _kSceneHeight = 210;

String _hex(Color c) =>
    '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

String _svg(String body) =>
    '<svg xmlns="http://www.w3.org/2000/svg" width="760" height="210" '
    'viewBox="0 0 760 210">$body</svg>';

/// Home, desk, monitor and the faint track of the link.
String _homeLayer(FuntiTokens t, FuntiSceneColors s) => _svg('''
<rect x="430" y="10" width="340" height="210" rx="22" fill="${_hex(s.home)}"/>
<path d="M466 152 L490 152 L486 172 L470 172 Z" fill="#C98E6B"/>
<ellipse cx="470" cy="136" rx="7" ry="15" transform="rotate(-28 470 136)" fill="#86A86E"/>
<ellipse cx="486" cy="134" rx="7" ry="16" transform="rotate(24 486 134)" fill="#6F9758"/>
<ellipse cx="478" cy="128" rx="6" ry="17" fill="#7FA36A"/>
<rect x="430" y="172" width="340" height="8" fill="${_hex(s.desk)}"/>
<rect x="430" y="180" width="340" height="40" fill="${_hex(s.deskFront)}"/>
<rect x="500" y="66" width="146" height="90" rx="8" fill="#2B2F3A"/>
<rect x="506" y="72" width="134" height="76" rx="4" fill="#F4F7FD"/>
<rect x="506" y="72" width="134" height="11" rx="4" fill="#E2E9F5"/>
<rect x="513" y="91" width="54" height="7" rx="3.5" fill="#1267EF"/>
<rect x="513" y="104" width="84" height="5" rx="2.5" fill="#CBD5E5"/>
<rect x="513" y="114" width="66" height="5" rx="2.5" fill="#CBD5E5"/>
<rect x="513" y="124" width="74" height="5" rx="2.5" fill="#CBD5E5"/>
<rect x="604" y="90" width="28" height="28" rx="5" fill="#E2E9F5"/>
<circle cx="573" cy="69" r="2.3" fill="#5B6270"/>
<rect x="567" y="156" width="12" height="12" fill="#3A3F4B"/>
<rect x="548" y="167" width="50" height="5" rx="2.5" fill="#3A3F4B"/>
<path d="M218 98 C 310 18, 470 4, 572 64" fill="none" stroke="${_hex(t.accent)}" stroke-opacity="0.22" stroke-width="2"/>
''');

/// The lock on the link and the person with the phone.
String _personLayer(FuntiTokens t, FuntiSceneColors s) => _svg('''
<circle cx="393" cy="30" r="14" fill="${_hex(t.banner)}" stroke="${_hex(t.accent)}" stroke-width="2"/>
<rect x="387.5" y="29" width="11" height="8.5" rx="1.8" fill="none" stroke="${_hex(t.accent)}" stroke-width="1.8"/>
<path d="M390 29 V26.5 a3 3 0 0 1 6 0 V29" fill="none" stroke="${_hex(t.accent)}" stroke-width="1.8"/>
<path d="M70 212 C 70 160, 86 134, 124 130 C 162 134, 178 160, 178 212 Z" fill="${_hex(s.hoodie)}"/>
<path d="M98 134 C 106 146, 142 146, 150 134 C 142 128, 106 128, 98 134 Z" fill="${_hex(s.hood)}"/>
<path d="M115 142 L114 160 M133 142 L134 160" stroke="#FFFFFF" stroke-opacity="0.85" stroke-width="2" stroke-linecap="round"/>
<path d="M146 164 L154 161 L162 164 L162 170 C162 175 158 178 154 180 C150 178 146 175 146 170 Z" fill="#FFFFFF" fill-opacity="0.92"/>
<rect x="117" y="114" width="14" height="18" fill="${_hex(s.skin)}"/>
<circle cx="99" cy="96" r="5.5" fill="${_hex(s.skin)}"/>
<circle cx="149" cy="96" r="5.5" fill="${_hex(s.skin)}"/>
<circle cx="124" cy="92" r="25" fill="${_hex(s.skin)}"/>
<path d="M98 92 C 95 70, 110 60, 126 62 C 142 62, 154 74, 150 92 C 146 80, 138 76, 128 76 C 118 76, 112 72, 108 70 C 104 76, 101 82, 98 92 Z" fill="${_hex(s.hair)}"/>
<path d="M114 97 Q117.5 99.5 121 97 M129 97 Q132.5 99.5 136 97" fill="none" stroke="${_hex(s.hair)}" stroke-width="2.2" stroke-linecap="round"/>
<path d="M119 107 Q125 111 131 107" fill="none" stroke="#B9785C" stroke-width="2" stroke-linecap="round"/>
<path d="M166 148 C 184 150, 192 140, 200 126 L212 134 C 204 152, 188 164, 168 164 Z" fill="${_hex(s.hoodie)}"/>
<g transform="rotate(-10 212 102)">
<rect x="197" y="78" width="30" height="48" rx="6" fill="#23262E"/>
<rect x="200" y="83" width="24" height="38" rx="3.5" fill="#EAF1FE"/>
<path d="M205.5 100 L207 92.5 L211 97 Z M218.5 100 L217 92.5 L213 97 Z" fill="#CFC8BD"/>
<circle cx="212" cy="102" r="7.5" fill="#CFC8BD"/>
<ellipse cx="212" cy="106" rx="4.2" ry="2.6" fill="#F4F1EC"/>
<path d="M212 95.5 L212 98.5 M209.5 96.5 L210 98.5 M214.5 96.5 L214 98.5" stroke="#6F685E" stroke-width="0.9" stroke-linecap="round"/>
<circle cx="209" cy="101.5" r="1.7" fill="#C9DA94"/>
<circle cx="215" cy="101.5" r="1.7" fill="#C9DA94"/>
<circle cx="212" cy="104.6" r="0.8" fill="#D49B86"/>
</g>
<circle cx="205" cy="131" r="8.5" fill="${_hex(s.skin)}"/>
''');

// Funtik is drawn in his own coordinates and placed next to the monitor.
const String _catPlacement = 'translate(652 70) scale(0.52)';

const String _tailLayer = '''
<g transform="$_catPlacement">
<path d="M118 182 C 150 186, 160 206, 152 244" fill="none" stroke="#CFC8BD" stroke-width="18" stroke-linecap="round"/>
<path d="M118 182 C 150 186, 160 206, 152 244" fill="none" stroke="#4E4943" stroke-width="18" stroke-dasharray="7 9"/>
<circle cx="152" cy="244" r="9" fill="#3F3B36"/>
</g>''';

const String _catBodyLayer = '''
<g transform="$_catPlacement">
<path d="M30 196 C 22 158, 34 120, 58 108 L102 108 C 126 120, 138 158, 130 196 Z" fill="#CFC8BD"/>
<path d="M30 196 C 22 158, 34 120, 58 108 L62 120 C 46 140, 42 170, 46 196 Z" fill="#B7AFA2"/>
<path d="M130 196 C 138 158, 126 120, 102 108 L98 120 C 114 140, 118 170, 114 196 Z" fill="#B7AFA2"/>
<path d="M33 150 C 41 148, 47 152, 51 157 M31 170 C 39 168, 45 172, 49 177 M127 150 C 119 148, 113 152, 109 157 M129 170 C 121 168, 115 172, 111 177" fill="none" stroke="#7A7368" stroke-width="4" stroke-linecap="round"/>
<ellipse cx="80" cy="138" rx="23" ry="30" fill="#F2EEE8"/>
<rect x="57" y="142" width="19" height="54" rx="9.5" fill="#DCD6CC"/>
<rect x="84" y="142" width="19" height="54" rx="9.5" fill="#DCD6CC"/>
<path d="M59 160 L74 160 M59 172 L74 172 M86 160 L101 160 M86 172 L101 172" stroke="#9C9488" stroke-width="2.4" stroke-linecap="round"/>
<ellipse cx="66.5" cy="194" rx="11.5" ry="6.5" fill="#F2EEE8"/>
<ellipse cx="93.5" cy="194" rx="11.5" ry="6.5" fill="#F2EEE8"/>
<path d="M32 54 C 30 36, 36 22, 44 14 C 52 20, 60 28, 66 36 Z" fill="#CFC8BD"/>
<path d="M39 45 C 39 35, 42 27, 46 22 C 51 27, 55 32, 58 37 Z" fill="#E8C9BC"/>
<path d="M128 54 C 130 36, 124 22, 116 14 C 108 20, 100 28, 94 36 Z" fill="#CFC8BD"/>
<path d="M121 45 C 121 35, 118 27, 114 22 C 109 27, 105 32, 102 37 Z" fill="#E8C9BC"/>
<path d="M28 70 C 28 42, 54 28, 80 28 C 106 28, 132 42, 132 70 C 132 96, 108 112, 80 112 C 52 112, 28 96, 28 70 Z" fill="#CFC8BD"/>
<path d="M36 82 C 44 101, 62 110, 80 110 C 98 110, 116 101, 124 82 C 110 92, 96 95, 80 95 C 64 95, 50 92, 36 82 Z" fill="#DCD6CC"/>
<path d="M80 30 C 83.5 40, 82.5 50, 80 60 C 77.5 50, 76.5 40, 80 30 Z M70 32 C 73 40, 72.5 48, 70.5 56 C 68.5 48, 67.5 40, 70 32 Z M90 32 C 92.5 40, 91.5 48, 89.5 56 C 87.5 48, 87 40, 90 32 Z M60 37 C 62.5 42, 62 48, 60.5 53 C 58.8 48, 58 42, 60 37 Z M100 37 C 102 42, 101.2 48, 99.5 53 C 98 48, 97.5 42, 100 37 Z" fill="#6F685E"/>
<path d="M37 76 C 43 77, 47 79, 50 82 M35 86 C 41 86, 45 88, 48 90 M123 76 C 117 77, 113 79, 110 82 M125 86 C 119 86, 115 88, 112 90" fill="none" stroke="#7A7368" stroke-width="2.6" stroke-linecap="round"/>
<ellipse cx="72" cy="92" rx="11" ry="8" fill="#F4F1EC"/>
<ellipse cx="88" cy="92" rx="11" ry="8" fill="#F4F1EC"/>
<ellipse cx="80" cy="101" rx="8" ry="5" fill="#F4F1EC"/>
</g>''';

String _eyeLayer(double cx) => '''
<g transform="$_catPlacement">
<circle cx="$cx" cy="70" r="11.5" fill="#C9DA94" stroke="#7D8A55" stroke-width="1.6"/>
<circle cx="$cx" cy="71" r="3.8" fill="#1F1E1B"/>
<circle cx="${cx + 3.5}" cy="66.5" r="2.4" fill="#FFFFFF"/>
</g>''';

const String _catFaceLayer = '''
<g transform="$_catPlacement">
<path d="M46 63 Q60 59 74 63 L74 55 L46 55 Z M86 63 Q100 59 114 63 L114 55 L86 55 Z" fill="#CFC8BD"/>
<path d="M47 63 Q60 59 73 63 M87 63 Q100 59 113 63" fill="none" stroke="#6F685E" stroke-width="1.8" stroke-linecap="round"/>
<path d="M75 86 C 75 84, 85 84, 85 86 C 85 88.5, 82 91, 80 92 C 78 91, 75 88.5, 75 86 Z" fill="#D49B86"/>
<path d="M80 92 L80 95 M80 95 C 77.5 98, 74 98, 72.5 96 M80 95 C 82.5 98, 86 98, 87.5 96" fill="none" stroke="#6F685E" stroke-width="1.7" stroke-linecap="round"/>
<path d="M64 92 L34 87 M64 95 L33 96 M64 98 L36 104 M96 92 L126 87 M96 95 L127 96 M96 98 L124 104" fill="none" stroke="#9A9387" stroke-width="1" stroke-linecap="round"/>
</g>''';

// Scene coordinates of the animated parts, derived from [_catPlacement].
const Offset _tailPivot = Offset(652 + 0.52 * 118, 70 + 0.52 * 182);
const Offset _leftEye = Offset(652 + 0.52 * 60, 70 + 0.52 * 70);
const Offset _rightEye = Offset(652 + 0.52 * 100, 70 + 0.52 * 70);

class FuntiHomeScene extends StatefulWidget {
  const FuntiHomeScene({Key? key}) : super(key: key);

  @override
  State<FuntiHomeScene> createState() => _FuntiHomeSceneState();
}

class _FuntiHomeSceneState extends State<FuntiHomeScene>
    with TickerProviderStateMixin {
  late final AnimationController _tail = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3200));
  late final AnimationController _blink =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final AnimationController _flow = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  bool? _animating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = !MediaQuery.of(context).disableAnimations;
    if (animate == _animating) return;
    _animating = animate;
    if (animate) {
      _tail.repeat(reverse: true);
      _blink.repeat();
      _flow.repeat();
    } else {
      _tail
        ..stop()
        ..value = 0.5;
      _blink
        ..stop()
        ..value = 0;
      _flow
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _tail.dispose();
    _blink.dispose();
    _flow.dispose();
    super.dispose();
  }

  // Eyes are open most of the time and close briefly at 93–100 % of the cycle.
  double _eyeScale(double v) {
    if (v < 0.93) return 1;
    if (v < 0.95) return 1 - (v - 0.93) / 0.02 * 0.92;
    return 0.08 + (v - 0.95) / 0.05 * 0.92;
  }

  Widget _layer(String svg) => SvgPicture.string(svg,
      width: _kSceneWidth, height: _kSceneHeight, fit: BoxFit.fill);

  Widget _eye(Offset center, double cx) => AnimatedBuilder(
        animation: _blink,
        builder: (context, child) => Transform(
          transform: Matrix4.identity()
            ..translate(center.dx, center.dy)
            ..scale(1.0, _eyeScale(_blink.value))
            ..translate(-center.dx, -center.dy),
          child: child,
        ),
        child: _layer(_svg(_eyeLayer(cx))),
      );

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final s = FuntiSceneColors.of(context);
    return Semantics(
      image: true,
      label: 'Человек с телефоном подключён к домашнему компьютеру, '
          'рядом с которым сидит кот Фунтик',
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.bottomRight,
          child: SizedBox(
            width: _kSceneWidth,
            height: _kSceneHeight,
            child: ClipRect(
              child: Stack(children: [
                _layer(_homeLayer(t, s)),
                CustomPaint(
                  size: const Size(_kSceneWidth, _kSceneHeight),
                  painter: _LinkDotsPainter(_flow, t.accent),
                ),
                _layer(_personLayer(t, s)),
                AnimatedBuilder(
                  animation: _tail,
                  builder: (context, child) => Transform(
                    transform: Matrix4.identity()
                      ..translate(_tailPivot.dx, _tailPivot.dy)
                      ..rotateZ(
                          (-6 + 14 * Curves.easeInOut.transform(_tail.value)) *
                              math.pi /
                              180)
                      ..translate(-_tailPivot.dx, -_tailPivot.dy),
                    child: child,
                  ),
                  child: _layer(_svg(_tailLayer)),
                ),
                _layer(_svg(_catBodyLayer)),
                _eye(_leftEye, 60),
                _eye(_rightEye, 100),
                _layer(_svg(_catFaceLayer)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dots running along the link from the phone to the webcam.
class _LinkDotsPainter extends CustomPainter {
  _LinkDotsPainter(this.progress, this.color) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  static final Path _link = Path()
    ..moveTo(218, 98)
    ..cubicTo(310, 18, 470, 4, 572, 64);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 10.0;
    final shift = progress.value * 2 * step;
    for (final metric in _link.computeMetrics()) {
      for (var d = shift % step; d <= metric.length; d += step) {
        final tangent = metric.getTangentForOffset(d);
        if (tangent != null) {
          canvas.drawCircle(tangent.position, 1.5, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_LinkDotsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.progress != progress;
}
