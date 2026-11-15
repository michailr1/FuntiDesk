// FUNTIDESK: checks for lib/funti/history_rules.dart (plain `dart`).
import '../../lib/funti/history_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  const now = 100000;
  final from = now - 86400;
  final h = funtiHistory({
    'op': 'history', 'days': 1, 'now': now, 'step': 300, 'boot': now - 3000,
    'samples': [
      [from + 300, 10, 50, 40],
      [from + 600, 20, 51, 40],
      // off for an hour
      [from + 4200, 5, 30, 40],
      'garbage',
      [now - 300, 7, 33, 41],
    ],
  })!;
  check('points', h.points.length, 4);
  check('off', h.off.map((o) => '${o[0] - from}-${o[1] - from}').join(','),
      '600-4200,4200-${86400 - 300}');
  check('off total', funtiHistoryOffSeconds(h), 3600 + 86400 - 300 - 4200);
  check('boot', h.boot, now - 3000);
  check('not history', funtiHistory({'op': 'status'}), null);
  final empty = funtiHistory({'op': 'history', 'days': 7, 'now': now, 'samples': []})!;
  check('empty off', empty.off.length, 1);
  check('week', empty.to - empty.from, 7 * 86400);

  if (failed > 0) throw 'history_rules: $failed check(s) failed';
  print('history_rules: ok');
}
