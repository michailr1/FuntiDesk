// FUNTIDESK: checks for lib/funti/journal_rules.dart (plain `dart`).
import '../../lib/funti/journal_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  // Newest first, as the service answers.
  final events = [
    {'t': 900, 'kind': 'refused', 'conn': 9, 'alarm': 2, 'ip': '192.0.2.9', 'peer': '', 'name': ''},
    {'t': 800, 'kind': 'connected', 'conn': 8, 'peer': '222', 'name': 'Папа', 'ip': '::1', 'type': 4},
    {'t': 700, 'kind': 'closed', 'conn': 7, 'seconds': 400},
    {'t': 600, 'kind': 'files', 'conn': 7, 'received': false, 'num': 1, 'bytes': 5, 'names': ['b.txt', 'a.jpg']},
    {'t': 500, 'kind': 'files', 'conn': 7, 'received': true, 'num': 2, 'bytes': 30, 'names': ['a.jpg', '']},
    {'t': 300, 'kind': 'connected', 'conn': 7, 'peer': '111', 'name': 'Мама', 'ip': '203.0.113.5', 'type': 0},
    {'t': 200, 'kind': 'files', 'conn': 3, 'received': true, 'num': 1, 'bytes': 1, 'peer': '333', 'ip': '::1'},
    {'t': 100, 'kind': 'closed', 'conn': 1, 'seconds': 5},
    'broken',
    {'t': 50, 'kind': 'unknown'},
  ];
  final rows = funtiJournalRows(events);
  check('kinds', rows.map((r) => r.kind).toList(), ['refused', 'session', 'session', 'files']);
  check('refused', '${rows[0].alarm} ${rows[0].ip}', '2 192.0.2.9');
  check('open session', '${rows[1].name} ${rows[1].type} ${rows[1].seconds}', 'Папа 4 null');
  final s = rows[2];
  check('closed session', '${s.name} ${s.peer} ${s.time} ${s.seconds}', 'Мама 111 300 400');
  check('received', '${s.received} ${s.receivedBytes}', '2 30');
  check('sent', '${s.sent} ${s.sentBytes}', '1 5');
  check('names', s.files, ['a.jpg', 'b.txt']);
  check('loose transfer', '${rows[3].peer} ${rows[3].received}', '333 1');

  // After "cleared" (or a restart of the numbering) an old number is not
  // mixed up with a new session.
  final again = funtiJournalRows([
    {'t': 40, 'kind': 'closed', 'conn': 1, 'seconds': 9},
    {'t': 30, 'kind': 'cleared'},
    {'t': 10, 'kind': 'connected', 'conn': 1, 'peer': '1', 'name': 'A', 'ip': '', 'type': 0},
  ]);
  check('cleared', again.map((r) => '${r.kind}:${r.seconds}').toList(), ['cleared:null', 'session:null']);
  check('empty', funtiJournalRows([]).length, 0);
  final admin = funtiJournalRows([
    {'t': 5, 'kind': 'admin', 'conn': 2, 'peer': '111', 'ip': '::1', 'action': 'kill', 'target': 'chrome.exe (5120)'},
  ]);
  check('admin', '${admin[0].kind} ${admin[0].peer} ${admin[0].name}', 'admin 111 chrome.exe (5120)');

  check('seconds', funtiJournalDuration(45, 'с', 'мин', 'ч'), '45 с');
  check('minutes', funtiJournalDuration(720, 'с', 'мин', 'ч'), '12 мин');
  check('hours', funtiJournalDuration(7500, 'с', 'мин', 'ч'), '2 ч 05 мин');

  if (failed > 0) throw 'journal_rules: $failed check(s) failed';
  print('journal_rules: ok');
}
