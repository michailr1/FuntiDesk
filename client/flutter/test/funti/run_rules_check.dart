// FUNTIDESK: checks for lib/funti/run_rules.dart (plain `dart`).
import '../../lib/funti/run_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  final run = FuntiRun('r1', 'powershell', 'hostname', ['a', 'b', 'c'], DateTime(2026));
  check('none yet', [run.finished, run.succeeded], [0, 0]);
  check('other run', run.onAnswer('a', {'op': 'run', 'id': 'r0', 'code': 0}), false);
  check('other op', run.onAnswer('a', {'op': 'status', 'id': 'r1'}), false);
  check('unknown host', run.onAnswer('z', {'op': 'run', 'id': 'r1', 'code': 0}), false);
  check('a', run.onAnswer('a', {'op': 'run', 'id': 'r1', 'code': 0, 'output': 'PC-1\r\n'}), true);
  run.onAnswer('b', {'op': 'run', 'id': 'r1', 'code': null, 'timedOut': true, 'output': ''});
  check('counts', [run.finished, run.succeeded], [2, 1]);
  check('b', [run.results['b']!.timedOut, run.results['b']!.ok], [true, false]);
  run.onAnswer('c', {'op': 'run', 'id': 'r1', 'error': 'funti-run-failed'});
  check('c', [run.results['c']!.error, run.results['c']!.ok], ['funti-run-failed', false]);
  check('report', run.report((h) => h.toUpperCase()),
      '=== A — code 0\nPC-1\n\n=== B — timeout\n\n\n=== C — funti-run-failed\n');
  check('request', funtiRunRequest('r1', 'cmd', 'ver', 60)['shell'], 'cmd');
  check('as user', [funtiRunRequest('r', 'cmd', 'x', 5).containsKey('asUser'), funtiRunRequest('r', 'cmd', 'x', 5, asUser: true)['asUser']], [false, true]);

  final up = FuntiRun('u1', 'update', '', ['a'], DateTime(2026));
  check('update answer', up.onAnswer('a', {'op': 'update', 'id': 'u1', 'code': 0, 'output': '1.5.3-ft.13500'}), true);
  check('update ok', up.results['a']!.ok, true);
  check('update request', funtiUpdateRequest('u1')['op'], 'update');

  if (failed > 0) throw 'run_rules: $failed check(s) failed';
  print('run_rules: ok');
}
