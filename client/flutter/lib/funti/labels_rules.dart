// FUNTIDESK (ADR-024): labels and a note per computer in the workplace,
// kept on the administrator's computer only (a local option, JSON).
// Plain Dart, checked by test/funti/labels_rules_check.dart.

import 'dart:convert';

class FuntiHostTags {
  final List<String> labels;
  final String note;
  const FuntiHostTags([this.labels = const [], this.note = '']);

  bool get isEmpty => labels.isEmpty && note.trim().isEmpty;
}

const funtiLabelsMax = 8;
const funtiLabelMax = 24;
const funtiNoteMax = 500;

/// "сервер, бухгалтерия,  ,Сервер" → ["сервер", "бухгалтерия"].
List<String> funtiParseLabels(String text) {
  final out = <String>[];
  for (final raw in text.split(RegExp(r'[,;\n]'))) {
    var l = raw.trim();
    if (l.isEmpty) continue;
    if (l.length > funtiLabelMax) l = l.substring(0, funtiLabelMax);
    if (out.any((x) => x.toLowerCase() == l.toLowerCase())) continue;
    out.add(l);
    if (out.length == funtiLabelsMax) break;
  }
  return out;
}

Map<String, FuntiHostTags> funtiTagsDecode(String json) {
  final out = <String, FuntiHostTags>{};
  try {
    final v = jsonDecode(json);
    if (v is! Map) return out;
    v.forEach((id, t) {
      if (t is! Map) return;
      final labels = t['labels'] is List
          ? funtiParseLabels((t['labels'] as List).whereType<String>().join(','))
          : <String>[];
      var note = t['note'] is String ? t['note'] as String : '';
      if (note.length > funtiNoteMax) note = note.substring(0, funtiNoteMax);
      final tags = FuntiHostTags(labels, note);
      if (!tags.isEmpty) out['$id'] = tags;
    });
  } catch (_) {}
  return out;
}

String funtiTagsEncode(Map<String, FuntiHostTags> tags) => jsonEncode({
      for (final e in tags.entries)
        if (!e.value.isEmpty) e.key: {'labels': e.value.labels, 'note': e.value.note}
    });

/// Every label in use, sorted, each once.
List<String> funtiAllLabels(Map<String, FuntiHostTags> tags) {
  final seen = <String, String>{};
  for (final t in tags.values) {
    for (final l in t.labels) {
      seen.putIfAbsent(l.toLowerCase(), () => l);
    }
  }
  final out = seen.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}

bool funtiHasLabel(FuntiHostTags? t, String label) =>
    t != null && t.labels.any((l) => l.toLowerCase() == label.toLowerCase());

/// The search also finds a computer by its labels and note.
bool funtiTagsMatch(FuntiHostTags? t, String search) {
  final s = search.trim().toLowerCase();
  if (s.isEmpty || t == null) return false;
  return t.labels.any((l) => l.toLowerCase().contains(s)) || t.note.toLowerCase().contains(s);
}
