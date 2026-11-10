// FUNTIDESK: checks for lib/funti/file_rules.dart. Plain `dart`, no
// package:test, so CI runs it without `pub get` of the whole app:
// scripts/ci/test-funti-dart.sh
import '../../lib/funti/file_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  // "Open" allowlist.
  check('doc', funtiIsOpenable('Отчёт.DOCX'), true);
  check('photo', funtiIsOpenable('IMG_1.jpeg'), true);
  check('exe', funtiIsOpenable('setup.exe'), false);
  check('double ext', funtiIsOpenable('invoice.pdf.exe'), false);
  check('shortcut', funtiIsOpenable('Word.lnk'), false);
  check('script', funtiIsOpenable('run.ps1'), false);
  check('no ext', funtiIsOpenable('README'), false);
  check('dot file', funtiIsOpenable('.txt'), false);
  check('trailing dot', funtiIsOpenable('a.'), false);

  // Free names.
  check('free', funtiFreeName('a.txt', (_) => false), 'a.txt');
  final taken = {'a.txt', 'a (2).txt'};
  check('next', funtiFreeName('a.txt', taken.contains), 'a (3).txt');
  check('no ext', funtiFreeName('dir', {'dir'}.contains), 'dir (2)');
  check('dot file', funtiFreeName('.env', {'.env'}.contains), '.env (2)');
  check('two dots', funtiFreeName('x.tar.gz', {'x.tar.gz'}.contains),
      'x.tar (2).gz');

  // Name conflicts.
  final names = ['A.txt', 'b.txt', 'c.txt'];
  final existing = ['a.txt', 'c.txt', 'c (2).txt'];
  check('clashes windows', funtiClashes(names, existing, true), [0, 2]);
  check('clashes linux', funtiClashes(names, existing, false), [2]);
  check('skip', funtiPlanSend(names, existing, true, FuntiConflict.skip),
      [(1, 'b.txt')]);
  check('replace', funtiPlanSend(names, existing, true, FuntiConflict.replace),
      [(0, 'A.txt'), (1, 'b.txt'), (2, 'c.txt')]);
  check(
      'keep both',
      funtiPlanSend(names, existing, true, FuntiConflict.keepBoth),
      [(0, 'A (2).txt'), (1, 'b.txt'), (2, 'c (3).txt')]);
  check('no clash, no choice', funtiPlanSend(['x'], existing, true, null),
      [(0, 'x')]);
  // Two items with the same name in one batch: the second does not
  // overwrite the first.
  check(
      'same batch',
      funtiPlanSend(
          ['d.txt', 'D.txt'], ['d.txt'], true, FuntiConflict.keepBoth),
      [(0, 'd (2).txt'), (1, 'D (3).txt')]);

  check('zone mark', funtiZoneIdentifier, '[ZoneTransfer]\r\nZoneId=3\r\n');

  if (failed > 0) throw 'file_rules: $failed check(s) failed';
  print('file_rules: ok');
}
