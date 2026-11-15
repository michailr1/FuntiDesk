// FUNTIDESK: checks for lib/funti/workplace_rules.dart (plain `dart`).
import '../../lib/funti/admin_rules.dart';
import '../../lib/funti/workplace_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

FuntiAdminStatus st(int cpu, int mem, int disk) =>
    FuntiAdminStatus(cpu, mem, disk, 'C:');

void main() {
  final a = FuntiHost('111', 'Бухгалтерия')..onState('ready', '');
  final b = FuntiHost('222', 'админ')..onState('ready', '');
  final c = FuntiHost('333', 'Зал')..onState('closed', funtiServiceOffline);
  final d = FuntiHost('444', 'архив')..onState('closed', funtiServiceNoAccess);
  final e = FuntiHost('555', 'Старый')..onState('closed', funtiServiceOld);
  final f = FuntiHost('666', 'new');
  a.status = st(10, 20, 30);
  b.status = st(10, 95, 30);
  final all = [a, b, c, d, e, f];

  check('problem', all.map((h) => h.problem).toList(), [false, true, false, false, false, false]);
  check('notes', all.map((h) => h.note).toList(), [
    '', '', 'funti-service-offline', 'funti-workplace-no-access',
    'funti-service-old-version', 'funti-workplace-connecting'
  ]);
  check('retry', all.map((h) => h.retry).toList(), [false, false, true, false, false, false]);
  check('wrong password', (FuntiHost('1', 'x')..onState('closed', 'Wrong Password')).note, 'funti-workplace-no-access');
  check('other error', (FuntiHost('1', 'x')..onState('closed', 'boom')).note, 'funti-workplace-no-connection');
  check('status dropped', (FuntiHost('1', 'x')
        ..onState('ready', '')
        ..status = st(1, 1, 1)
        ..onState('closed', funtiServiceOffline))
      .status, null);

  check('problems first', funtiHostsSorted(all, '', true).map((h) => h.id).toList(),
      ['222', '111', 'new', 'архив', 'Зал', 'Старый'].map((n) => all.firstWhere((h) => h.name == n || h.id == n).id).toList());
  check('by name', funtiHostsSorted(all, '', false).map((h) => h.name).toList(),
      ['new', 'админ', 'архив', 'Бухгалтерия', 'Зал', 'Старый']);
  check('search name', funtiHostsSorted(all, ' БУХ ', true).map((h) => h.id).toList(), ['111']);
  check('search id', funtiHostsSorted(all, '44', true).map((h) => h.id).toList(), ['444']);

  // Alerts.
  final t = FuntiAlertTracker(memorySeconds: 180);
  check('calm', t.onStatus(a, st(5, 50, 50), 0).length, 0);
  final disk = t.onStatus(a, st(5, 50, 95), 10);
  check('disk once', '${disk.length} ${disk[0].kind} ${disk[0].value} ${disk[0].hostName}', '1 disk 95 Бухгалтерия');
  check('disk not again', t.onStatus(a, st(5, 50, 96), 20).length, 0);
  check('disk gone', t.onStatus(a, st(5, 50, 80), 30).length, 0);
  check('disk again', t.onStatus(a, st(5, 50, 91), 40).map((x) => x.kind).toList(), ['disk']);
  check('memory starts', t.onStatus(b, st(5, 95, 10), 100).length, 0);
  check('memory short', t.onStatus(b, st(5, 96, 10), 200).length, 0);
  check('memory long', t.onStatus(b, st(5, 97, 10), 280).map((x) => '${x.kind}${x.value}').toList(), ['memory97']);
  check('memory not again', t.onStatus(b, st(5, 99, 10), 400).length, 0);
  check('memory dip resets', t.onStatus(b, st(5, 50, 10), 410).length, 0);
  check('memory restart', t.onStatus(b, st(5, 95, 10), 420).length, 0);
  check('no disk name', t.onStatus(b, FuntiAdminStatus(1, 1, 99, ''), 430).length, 0);
  check('lost', t.onClosed(a, funtiServiceOffline, 500).map((x) => x.kind).toList(), ['lost']);
  check('lost once', t.onClosed(a, funtiServiceOffline, 510).length, 0);
  check('closed by us', t.onClosed(b, 'closed', 520).length, 0);
  check('never connected', t.onClosed(c, funtiServiceOffline, 530).length, 0);

  final g = FuntiHost('777', 'Касса')..onState('ready', '');
  check('calm', g.problem, false);
  g.attention = funtiAttentionItems({
    'op': 'attention',
    'items': [
      {'kind': 'restart', 'level': 'warning', 'detail': ''},
      'мусор',
    ]
  });
  check('attention', [g.attention.length, g.problem], [1, true]);
  g.onState('closed', funtiServiceOffline);
  check('attention gone', [g.attention.length, g.problem], [0, false]);
  check('no items', funtiAttentionItems({'op': 'attention'}).length, 0);

  if (failed > 0) throw 'workplace_rules: $failed check(s) failed';
  print('workplace_rules: ok');
}
