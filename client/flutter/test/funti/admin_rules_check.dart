// FUNTIDESK: checks for lib/funti/admin_rules.dart (plain `dart`).
import '../../lib/funti/admin_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  final s = FuntiAdminStatus.parse({
    'op': 'status', 'cpu': 42, 'mem_used': 6, 'mem_total': 16,
    'disk_used': 95, 'disk_total': 100, 'disk': 'C:'
  })!;
  check('status', '${s.cpu} ${s.memory} ${s.disk} ${s.diskName} ${s.hot}', '42 38 95 C: true');
  final calm = FuntiAdminStatus.parse({'op': 'status', 'cpu': 90, 'mem_used': 9, 'mem_total': 10})!;
  check('no disk', '${calm.memory} ${calm.disk} "${calm.diskName}" ${calm.hot}', '90 0 "" false');
  check('cpu over', FuntiAdminStatus.parse({'op': 'status', 'cpu': 250})!.cpu, 100);
  check('error', FuntiAdminStatus.parse({'op': 'status', 'error': 'x'}), null);
  check('other op', FuntiAdminStatus.parse({'op': 'processes'}), null);
  check('garbage', FuntiAdminStatus.parse('x'), null);

  final list = funtiAdminProcesses({
    'op': 'processes',
    'processes': [
      {'pid': 10, 'name': 'chrome.exe', 'cpu': 12.5, 'mem': 900, 'user': 'Мама', 'protected': false},
      {'pid': 11, 'name': 'Notepad.exe', 'cpu': 0, 'mem': 50, 'user': 'Мама'},
      {'pid': 4, 'name': 'System', 'cpu': 0.3, 'mem': 2000, 'user': '', 'protected': true},
      {'pid': 12, 'name': 'CHROME_helper', 'cpu': 12.5, 'mem': 100, 'user': 'Мама'},
      'broken',
    ]
  })!;
  check('parsed', list.length, 4);
  check('protected', list.where((p) => p.protected).map((p) => p.name).toList(), ['System']);
  check('by cpu', funtiAdminSorted(list, '', false).map((p) => p.pid).toList(), [10, 12, 4, 11]);
  check('by memory', funtiAdminSorted(list, '', true).map((p) => p.pid).toList(), [4, 10, 12, 11]);
  check('search', funtiAdminSorted(list, ' Chrome ', false).map((p) => p.pid).toList(), [10, 12]);
  check('search none', funtiAdminSorted(list, 'zzz', false).length, 0);
  check('not a list', funtiAdminProcesses({'op': 'processes'}), null);
  check('other answer', funtiAdminProcesses({'op': 'status'}), null);

  final services = funtiAdminServices({
    'op': 'services',
    'services': [
      {'name': 'Spooler', 'display': 'Диспетчер печати', 'state': 'running', 'start': 'auto'},
      {'name': 'WinDefend', 'display': '', 'state': 'running', 'start': 'auto', 'protected': true},
      {'name': 'wuauserv', 'display': 'Центр обновления Windows', 'state': 'stopped', 'start': 'manual'},
      {'name': ''},
      7,
    ]
  })!;
  check('services', services.map((s) => s.display).toList(),
      ['Диспетчер печати', 'WinDefend', 'Центр обновления Windows']);
  check('service flags', '${services[0].running} ${services[2].stopped} ${services[1].protected}', 'true true true');
  check('service search display', funtiAdminServicesShown(services, 'печат').map((s) => s.name).toList(), ['Spooler']);
  check('service search name', funtiAdminServicesShown(services, 'WUAU').map((s) => s.name).toList(), ['wuauserv']);
  check('services other op', funtiAdminServices({'op': 'processes'}), null);

  final auto = funtiAdminAutostart({
    'op': 'autostart',
    'entries': [
      {'source': 'user', 'name': 'Steam', 'command': 'steam.exe -silent', 'enabled': true},
      {'source': 'machine32', 'name': 'Updater', 'command': 'u.exe', 'enabled': false},
      {'source': 'machine', 'name': 'FuntiDesk', 'command': 'f.exe', 'protected': true},
      {'source': '', 'name': 'x'},
      {'name': 'no source'},
    ]
  })!;
  check('autostart', auto.map((e) => '${e.name}:${e.enabled}:${e.everyone}:${e.protected}').toList(),
      ['Steam:true:false:false', 'Updater:false:true:false', 'FuntiDesk:true:true:true']);
  check('autostart other op', funtiAdminAutostart({'op': 'services'}), null);

  if (failed > 0) throw 'admin_rules: $failed check(s) failed';
  print('admin_rules: ok');
}
