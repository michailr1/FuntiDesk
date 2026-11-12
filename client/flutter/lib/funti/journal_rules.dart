// FUNTIDESK (ADR-020): turns the journal events of the service into rows for
// the settings page. No imports: checked by scripts/ci/test-funti-dart.sh.

/// One row of the journal page.
class FuntiJournalRow {
  /// "session", "files" (a transfer outside a known session), "refused",
  /// "admin" (name is what was acted on) or "cleared".
  final String kind;

  /// Unix time, seconds.
  final int time;
  final String peer;
  final String name;
  final String ip;

  /// Session: 0 screen, 1 files, 2 port forward, 3 camera, 4 terminal.
  int type = 0;

  /// Session length; null while it is open (or its end was not written).
  int? seconds;

  /// Refused: the number of the reason.
  int alarm = 0;

  int received = 0, receivedBytes = 0, sent = 0, sentBytes = 0;

  /// Names of the largest transferred files, without repeats.
  final List<String> files = [];

  FuntiJournalRow(this.kind, this.time, this.peer, this.name, this.ip);
}

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);
String _str(dynamic v) => v is String ? v : '';

/// [events] as the service gives them: newest first. Rows: newest first.
List<FuntiJournalRow> funtiJournalRows(List<dynamic> events) {
  final rows = <FuntiJournalRow>[];
  final open = <int, FuntiJournalRow>{};
  for (final e in events.reversed) {
    if (e is! Map) continue;
    final conn = _int(e['conn']);
    final t = _int(e['t']);
    switch (_str(e['kind'])) {
      case 'connected':
        final row = FuntiJournalRow('session', t, _str(e['peer']),
            _str(e['name']), _str(e['ip']))
          ..type = _int(e['type']);
        open[conn] = row;
        rows.add(row);
        break;
      case 'closed':
        open.remove(conn)?.seconds = _int(e['seconds']);
        break;
      case 'files':
        var row = open[conn];
        if (row == null) {
          row = FuntiJournalRow('files', t, _str(e['peer']), '', _str(e['ip']));
          rows.add(row);
        }
        if (e['received'] == true) {
          row.received += _int(e['num']);
          row.receivedBytes += _int(e['bytes']);
        } else {
          row.sent += _int(e['num']);
          row.sentBytes += _int(e['bytes']);
        }
        final names = e['names'];
        if (names is List) {
          for (final n in names) {
            if (n is String && n.isNotEmpty && !row.files.contains(n)) {
              row.files.add(n);
            }
          }
        }
        break;
      case 'refused':
        rows.add(FuntiJournalRow(
            'refused', t, _str(e['peer']), _str(e['name']), _str(e['ip']))
          ..alarm = _int(e['alarm']));
        break;
      case 'admin':
        // ADR-023: an action through the administration layer.
        rows.add(FuntiJournalRow(
            'admin', t, _str(e['peer']), _str(e['target']), _str(e['ip'])));
        break;
      case 'cleared':
        // The service restarted its connection numbers or the journal was
        // emptied: nothing before this belongs to a later session.
        open.clear();
        rows.add(FuntiJournalRow('cleared', t, '', '', ''));
        break;
    }
  }
  return rows.reversed.toList();
}

/// "45 с", "12 мин", "2 ч 05 мин" — the units come from the caller.
String funtiJournalDuration(int seconds, String s, String min, String h) {
  if (seconds < 60) return '$seconds $s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes $min';
  return '${minutes ~/ 60} $h ${(minutes % 60).toString().padLeft(2, '0')} $min';
}
