// FUNTIDESK (ADR-025): the history of a computer as the workplace draws it —
// points of load and the stretches when it was off. Plain Dart, checked by
// test/funti/history_rules_check.dart.

class FuntiHistoryPoint {
  final int t, cpu, memory, disk;
  const FuntiHistoryPoint(this.t, this.cpu, this.memory, this.disk);
}

class FuntiHistory {
  final int from, to, step;
  final List<FuntiHistoryPoint> points;

  /// [start, end) in seconds when there are no lines: off, asleep or no
  /// FuntiDesk.
  final List<List<int>> off;
  final int boot;
  FuntiHistory(this.from, this.to, this.step, this.points, this.off, this.boot);
}

int _i(Object? v) => v is num ? v.toInt() : 0;

/// null for an answer that is not a history.
FuntiHistory? funtiHistory(Map<String, dynamic> a) {
  if (a['op'] != 'history' || a['samples'] is! List) return null;
  final now = _i(a['now']);
  final days = _i(a['days']) == 7 ? 7 : 1;
  final step = _i(a['step']) > 0 ? _i(a['step']) : 300;
  final from = now - days * 86400;
  final points = <FuntiHistoryPoint>[
    for (final s in a['samples'] as List)
      if (s is List && s.length >= 4)
        FuntiHistoryPoint(_i(s[0]), _i(s[1]), _i(s[2]), _i(s[3]))
  ]..sort((x, y) => x.t.compareTo(y.t));
  // A gap longer than two steps: no lines, so the computer was not on.
  final off = <List<int>>[];
  var last = from;
  for (final p in points) {
    if (p.t - last > 2 * step) off.add([last, p.t]);
    last = p.t;
  }
  if (now - last > 2 * step) off.add([last, now]);
  return FuntiHistory(from, now, step, points, off, _i(a['boot']));
}

/// Hours and minutes it was off in total.
int funtiHistoryOffSeconds(FuntiHistory h) =>
    h.off.fold(0, (sum, o) => sum + (o[1] - o[0]));
