// FUNTIDESK: checks for lib/funti/inventory_rules.dart (plain `dart`).
import '../../lib/funti/inventory_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  final full = FuntiInventoryRow('Бухгалтерия', '100 200 301', 'в сети', {
    'os': 'Windows 11 Pro', 'maker': 'LENOVO', 'model': '20XW', 'cpu': 'Intel i5',
    'memory': 16 * 1024 * 1024 * 1024, 'gpus': ['Intel UHD'], 'user': 'anna', 'vm': '',
    'disks': [{'name': 'C:\\', 'size': 512 * 1024 * 1024 * 1024}],
  }, {
    'serial': 'PF3ABC12',
    'drives': [{'name': 'Samsung SSD', 'media': 'SSD', 'size': 1000204886016, 'health': 'Healthy'}],
  });
  final v = funtiInventoryValues(full);
  check('columns', v.length, funtiInventoryColumns.length);
  check('model', v[4], 'LENOVO 20XW');
  check('serial', v[5], 'PF3ABC12');
  check('memory', v[7], '16.0 GB');
  check('drives', v[8], 'Samsung SSD SSD 932 GB Healthy');
  final bare = FuntiInventoryRow('Ноутбук', '300 400 500', 'не в сети', null, null);
  check('bare', funtiInventoryValues(bare).skip(3).every((x) => x.isEmpty), true);
  final noSmart = FuntiInventoryRow('X', '1', '', {'disks': [{'name': 'C:\\', 'size': 1073741824}]}, null);
  check('disks fallback', funtiInventoryValues(noSmart)[8], 'C:\\ 1.0 GB');
  final csv = funtiInventoryCsv(['Имя', 'ID'], [
    FuntiInventoryRow('A; "B"', '1', '', null, null),
  ]);
  check('bom', csv.startsWith('\uFEFF'), true);
  check('csv', csv.substring(1).split('\r\n')[1].split(';').first, '"A');
  check('quoted', csv.contains('"A; ""B"""'), true);

  if (failed > 0) throw 'inventory_rules: $failed check(s) failed';
  print('inventory_rules: ok');
}
