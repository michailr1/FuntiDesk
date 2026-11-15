// FUNTIDESK (ADR-024, stage 5): the inventory of the workplace — one row
// per computer from its `info` and `hardware` answers, and CSV for Excel.
// Plain Dart, checked by test/funti/inventory_rules_check.dart.

class FuntiInventoryRow {
  final String name, id, online;
  final Map<String, dynamic>? info, hardware;
  FuntiInventoryRow(this.name, this.id, this.online, this.info, this.hardware);
}

String _gb(Object? bytes) {
  if (bytes is! num || bytes <= 0) return '';
  final gb = bytes / (1024 * 1024 * 1024);
  return '${gb >= 100 ? gb.round() : gb.toStringAsFixed(1)} GB';
}

String _s(Map<String, dynamic>? m, String k) =>
    m?[k] is String ? (m![k] as String).trim() : '';

/// Column keys (translation "funti-inventory-<key>") and their values.
const funtiInventoryColumns = [
  'name', 'id', 'online', 'os', 'model', 'serial', 'cpu', 'memory',
  'drives', 'gpu', 'user', 'vm',
];

List<String> funtiInventoryValues(FuntiInventoryRow r) {
  final i = r.info, h = r.hardware;
  final drives = h?['drives'] is List
      ? (h!['drives'] as List)
          .whereType<Map>()
          .map((d) => [
                '${d['name'] ?? ''}'.trim(),
                '${d['media'] ?? ''}',
                _gb(d['size']),
                '${d['health'] ?? ''}',
              ].where((x) => x.isNotEmpty).join(' '))
          .join('; ')
      : (i?['disks'] is List
          ? (i!['disks'] as List)
              .whereType<Map>()
              .map((d) => '${d['name'] ?? ''} ${_gb(d['size'])}'.trim())
              .join('; ')
          : '');
  return [
    r.name,
    r.id,
    r.online,
    _s(i, 'os'),
    [_s(i, 'maker'), _s(i, 'model')].where((x) => x.isNotEmpty).join(' '),
    _s(h, 'serial'),
    _s(i, 'cpu'),
    _gb(i?['memory']),
    drives,
    i?['gpus'] is List ? (i!['gpus'] as List).whereType<String>().join(', ') : '',
    _s(i, 'user'),
    _s(i, 'vm'),
  ];
}

String _cell(String v) {
  final needs = v.contains(';') || v.contains('"') || v.contains('\n') || v.contains(',');
  return needs ? '"${v.replaceAll('"', '""')}"' : v;
}

/// CSV with ";" between cells (Excel in Russian opens it as columns) and a
/// BOM so that Cyrillic letters are read as UTF-8.
String funtiInventoryCsv(List<String> header, Iterable<FuntiInventoryRow> rows) {
  final lines = [
    header.map(_cell).join(';'),
    for (final r in rows) funtiInventoryValues(r).map(_cell).join(';'),
  ];
  return '\uFEFF${lines.join('\r\n')}\r\n';
}
