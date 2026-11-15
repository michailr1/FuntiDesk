// FUNTIDESK: checks for lib/funti/labels_rules.dart (plain `dart`).
import '../../lib/funti/labels_rules.dart';

var failed = 0;

void check(String what, Object? got, Object? want) {
  if ('$got' != '$want') {
    failed++;
    print('FAIL $what: got $got, want $want');
  }
}

void main() {
  check('parse', funtiParseLabels('сервер, бухгалтерия,  ,Сервер;офис\nдом'),
      ['сервер', 'бухгалтерия', 'офис', 'дом']);
  check('long label', funtiParseLabels('x' * 40).first.length, funtiLabelMax);
  check('max labels', funtiParseLabels(List.generate(20, (i) => 'l$i').join(',')).length,
      funtiLabelsMax);
  final tags = {
    '111': FuntiHostTags(['сервер', 'офис'], 'стойка 2'),
    '222': FuntiHostTags(['Офис'], ''),
    '333': const FuntiHostTags(),
  };
  final back = funtiTagsDecode(funtiTagsEncode(tags));
  check('round trip', back.keys.toList(), ['111', '222']);
  check('note', back['111']!.note, 'стойка 2');
  check('all labels', funtiAllLabels(back), ['офис', 'сервер']);
  check('has label', [funtiHasLabel(back['222'], 'ОФИС'), funtiHasLabel(back['222'], 'сервер')],
      [true, false]);
  check('search', [funtiTagsMatch(back['111'], 'стойк'), funtiTagsMatch(back['111'], 'дом')],
      [true, false]);
  check('garbage', funtiTagsDecode('not json').length, 0);
  check('bad shape', funtiTagsDecode('{"1": 5, "2": {"labels": [3, "a"], "note": 7}}')['2']!.labels,
      ['a']);

  if (failed > 0) throw 'labels_rules: $failed check(s) failed';
  print('labels_rules: ok');
}
