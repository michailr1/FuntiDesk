// FUNTIDESK (ADR-024, stage 7): a command on several computers — what the
// window keeps of each answer. Plain Dart, checked by
// test/funti/run_rules_check.dart.

class FuntiRunResult {
  final String hostId;

  /// null while it runs.
  int? code;
  bool done = false, timedOut = false, cut = false;
  String output = '';
  String error = '';

  FuntiRunResult(this.hostId);

  bool get ok => done && error.isEmpty && !timedOut && code == 0;

  void onAnswer(Map<String, dynamic> a) {
    done = true;
    final c = a['code'];
    code = c is num ? c.toInt() : null;
    timedOut = a['timedOut'] == true;
    cut = a['cut'] == true;
    output = a['output'] is String ? a['output'] as String : '';
    error = a['error'] is String ? a['error'] as String : '';
  }
}

/// One run on several hosts.
class FuntiRun {
  final String id;
  final String shell, script;
  final DateTime started;
  final results = <String, FuntiRunResult>{};

  FuntiRun(this.id, this.shell, this.script, Iterable<String> hosts, this.started) {
    for (final h in hosts) {
      results[h] = FuntiRunResult(h);
    }
  }

  int get finished => results.values.where((r) => r.done).length;
  int get succeeded => results.values.where((r) => r.ok).length;

  /// The answer of a host to this run; false if it is not about this run.
  bool onAnswer(String hostId, Map<String, dynamic> a) {
    if (a['op'] != 'run' || a['id'] != id) return false;
    final r = results[hostId];
    if (r == null) return false;
    r.onAnswer(a);
    return true;
  }

  /// All answers as text, to copy.
  String report(String Function(String hostId) name) => [
        for (final r in results.values)
          '=== ${name(r.hostId)} — ${!r.done ? '…' : (r.timedOut ? 'timeout' : (r.error.isNotEmpty ? r.error : 'code ${r.code}'))}\n${r.output.trimRight()}'
      ].join('\n\n');
}

/// The request to send to each host.
Map<String, dynamic> funtiRunRequest(
        String id, String shell, String script, int timeout) =>
    {'op': 'run', 'id': id, 'shell': shell, 'script': script, 'timeout': timeout};
