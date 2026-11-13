// FUNTIDESK: checks for lib/funti/eventlog_rules.dart (plain `dart`).
import '../../lib/funti/eventlog_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  final t = funtiEventTime('2026-11-13T10:12:01.1234567Z')!.toUtc();
  check('time', [t.hour, t.minute, t.second, t.millisecond, t.microsecond], [10, 12, 1, 123, 456]);
  check('no time', funtiEventTime(''), null);
  check('bad time', funtiEventTime('вчера'), null);

  final events = funtiEvents({
    'op': 'eventlog',
    'events': [
      {'time': '2026-11-13T10:12:01Z', 'level': 1, 'source': 'Kernel-Power', 'id': 41,
        'message': '\r\nСистема перезагрузилась без завершения работы.\r\nПодробнее…'},
      {'time': '2026-11-13T10:00:00Z', 'level': 3, 'source': 'Disk', 'id': 153, 'message': ''},
      {'time': '2026-11-13T09:00:00Z', 'level': 0, 'source': 'Security-Auditing', 'id': 4625,
        'failure': true, 'message': 'Не удалось выполнить вход в учётную запись.'},
      'мусор',
    ],
  });
  check('count', events.length, 3);
  check('title', events[0].title, 'Система перезагрузилась без завершения работы.');
  check('empty title', events[1].title, '');
  check('bad', events.map((e) => e.bad).toList(), [true, false, true]);
  check('warning', events.map((e) => e.warning).toList(), [false, true, false]);
  check('filter source', events.where((e) => e.matches('disk')).length, 1);
  check('filter id', events.where((e) => e.matches(' 4625 ')).length, 1);
  check('filter text', events.where((e) => e.matches('ВХОД')).length, 1);
  check('filter none', events.where((e) => e.matches('')).length, 3);
  check('no events', funtiEvents({'op': 'eventlog', 'error': 'x'}).length, 0);

  if (failed > 0) throw 'eventlog_rules: $failed check(s) failed';
  print('eventlog_rules: ok');
}
