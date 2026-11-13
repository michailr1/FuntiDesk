// FUNTIDESK (ADR-024, stage 5): Windows event logs as the other computer
// sends them (`eventlog` answer). Plain Dart, checked by
// test/funti/eventlog_rules_check.dart.

/// One event of a Windows log.
class FuntiEvent {
  final DateTime? time;

  /// 0 or 4 information, 1 critical, 2 error, 3 warning.
  final int level;
  final String source;
  final int id;

  /// Security log: "audit failure".
  final bool failure;
  final String message;

  FuntiEvent(this.time, this.level, this.source, this.id, this.failure,
      this.message);

  bool get bad => level == 1 || level == 2 || failure;
  bool get warning => level == 3;

  /// The first line of the message, for the list.
  String get title {
    final line = message.split(RegExp(r'[\r\n]')).firstWhere(
        (l) => l.trim().isNotEmpty,
        orElse: () => '');
    return line.trim();
  }

  bool matches(String filter) {
    final f = filter.trim().toLowerCase();
    if (f.isEmpty) return true;
    return source.toLowerCase().contains(f) ||
        '$id' == f ||
        message.toLowerCase().contains(f);
  }
}

/// "2026-11-13T10:12:01.1234567Z" (seven digits of a second, as Windows
/// keeps it) → local time; null if it is not a time.
DateTime? funtiEventTime(String s) {
  final trimmed = s.replaceFirstMapped(
      RegExp(r'(\.\d{6})\d+'), (m) => m.group(1)!);
  return DateTime.tryParse(trimmed)?.toLocal();
}

int _int(Object? v) => v is num ? v.toInt() : 0;

/// The events of an `eventlog` answer, newest first as sent.
List<FuntiEvent> funtiEvents(Map<String, dynamic> answer) {
  final events = answer['events'];
  if (events is! List) return const [];
  return [
    for (final e in events)
      if (e is Map)
        FuntiEvent(
          funtiEventTime('${e['time'] ?? ''}'),
          _int(e['level']),
          '${e['source'] ?? ''}',
          _int(e['id']),
          e['failure'] == true,
          '${e['message'] ?? ''}',
        )
  ];
}
