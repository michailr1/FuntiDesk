// FUNTIDESK (ADR-025): the load of a computer over a day or a week, with the
// stretches when it was off.

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../funti/history_rules.dart';

const _cpuColor = Color(0xFF2F6FED);
const _memoryColor = Color(0xFF8E44AD);
const _diskColor = Color(0xFFE67E22);

class FuntiHistoryChart extends StatelessWidget {
  final FuntiHistory history;
  const FuntiHistoryChart({Key? key, required this.history}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final off = funtiHistoryOffSeconds(history);
    Widget legend(Color c, String key) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 3, color: c),
          const SizedBox(width: 4),
          Text(translate(key), style: TextStyle(fontSize: 11, color: t.muted)),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 140,
        child: CustomPaint(
          size: Size.infinite,
          painter: _Painter(history, t.rowStroke, t.surface2, t.muted),
        ),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 14, runSpacing: 4, children: [
        legend(_cpuColor, 'funti-workplace-cpu'),
        legend(_memoryColor, 'funti-workplace-memory'),
        legend(_diskColor, 'funti-admin-disk'),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, color: t.surface2),
          const SizedBox(width: 4),
          Text(
              translate('funti-history-off')
                  .replaceAll('{}', '${off ~/ 3600}')
                  .replaceAll('{m}', '${(off % 3600) ~/ 60}'),
              style: TextStyle(fontSize: 11, color: t.muted)),
        ]),
      ]),
    ]);
  }
}

class _Painter extends CustomPainter {
  final FuntiHistory h;
  final Color grid, offColor, label;
  _Painter(this.h, this.grid, this.offColor, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 28.0, bottom = 16.0;
    final w = size.width - left, ht = size.height - bottom;
    final span = (h.to - h.from).clamp(1, 1 << 31);
    double x(int t) => left + (t - h.from) / span * w;
    double y(int v) => ht - v.clamp(0, 100) / 100 * ht;
    final text = TextPainter(textDirection: TextDirection.ltr);
    void write(String s, Offset at) {
      text.text = TextSpan(text: s, style: TextStyle(fontSize: 9, color: label));
      text.layout();
      text.paint(canvas, at);
    }

    for (final o in h.off) {
      canvas.drawRect(Rect.fromLTRB(x(o[0]), 0, x(o[1]), ht), Paint()..color = offColor);
    }
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in [0, 50, 100]) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width, y(v)), gridPaint);
      write('$v%', Offset(0, y(v) - 6));
    }
    // Hours for a day, dates for a week.
    final week = span > 2 * 86400;
    final tick = week ? 86400 : 6 * 3600;
    for (var t = h.from - h.from % tick + tick; t < h.to; t += tick) {
      final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      canvas.drawLine(Offset(x(t), 0), Offset(x(t), ht), gridPaint);
      write(week ? '${d.day}.${d.month.toString().padLeft(2, '0')}' : '${d.hour}:00',
          Offset(x(t) + 2, ht + 2));
    }
    void line(int Function(FuntiHistoryPoint) v, Color c) {
      final paint = Paint()
        ..color = c
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final path = Path();
      FuntiHistoryPoint? prev;
      for (final p in h.points) {
        // Do not draw across a stretch when it was off.
        if (prev == null || p.t - prev.t > 2 * h.step) {
          path.moveTo(x(p.t), y(v(p)));
        } else {
          path.lineTo(x(p.t), y(v(p)));
        }
        prev = p;
      }
      canvas.drawPath(path, paint);
    }

    line((p) => p.disk, _diskColor);
    line((p) => p.memory, _memoryColor);
    line((p) => p.cpu, _cpuColor);
  }

  @override
  bool shouldRepaint(covariant _Painter old) => old.h != h;
}
