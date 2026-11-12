// FUNTIDESK (ADR-023): the administration layer — what the state bar and the
// process list show. No imports: checked by scripts/ci/test-funti-dart.sh.

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);
double _double(dynamic v) => v is num ? v.toDouble() : 0;
String _str(dynamic v) => v is String ? v : '';

int _percent(int used, int total) =>
    total <= 0 ? 0 : (used * 100 / total).round().clamp(0, 100);

/// Above this a value is shown as overloaded.
const funtiAdminHot = 90;

/// Processor, memory and system disk of the other computer, in percent.
class FuntiAdminStatus {
  final int cpu, memory, disk;

  /// "C:" or "/"; empty when the disk was not found.
  final String diskName;

  FuntiAdminStatus(this.cpu, this.memory, this.disk, this.diskName);

  static FuntiAdminStatus? parse(dynamic answer) {
    if (answer is! Map || answer['op'] != 'status' || answer['error'] != null) {
      return null;
    }
    final diskTotal = _int(answer['disk_total']);
    return FuntiAdminStatus(
        _int(answer['cpu']).clamp(0, 100),
        _percent(_int(answer['mem_used']), _int(answer['mem_total'])),
        _percent(_int(answer['disk_used']), diskTotal),
        diskTotal > 0 ? _str(answer['disk']) : '');
  }

  bool get hot =>
      cpu > funtiAdminHot || memory > funtiAdminHot || disk > funtiAdminHot;
}

class FuntiAdminProcess {
  final int pid, memory;
  final String name, user;
  final double cpu;

  /// The other side will not end it (system processes, FuntiDesk itself).
  final bool protected;

  FuntiAdminProcess(
      this.pid, this.name, this.cpu, this.memory, this.user, this.protected);
}

List<FuntiAdminProcess>? funtiAdminProcesses(dynamic answer) {
  if (answer is! Map || answer['op'] != 'processes') return null;
  final list = answer['processes'];
  if (list is! List) return null;
  return [
    for (final p in list)
      if (p is Map && _int(p['pid']) > 0 || p is Map && _str(p['name']).isNotEmpty)
        FuntiAdminProcess(_int(p['pid']), _str(p['name']), _double(p['cpu']),
            _int(p['mem']), _str(p['user']), p['protected'] == true)
  ];
}

class FuntiAdminService {
  final String name, display, state, start;
  final bool protected;
  FuntiAdminService(
      this.name, this.display, this.state, this.start, this.protected);

  bool get running => state == 'running';
  bool get stopped => state == 'stopped';
}

List<FuntiAdminService>? funtiAdminServices(dynamic answer) {
  if (answer is! Map || answer['op'] != 'services') return null;
  final list = answer['services'];
  if (list is! List) return null;
  return [
    for (final s in list)
      if (s is Map && _str(s['name']).isNotEmpty)
        FuntiAdminService(
            _str(s['name']),
            _str(s['display']).isEmpty ? _str(s['name']) : _str(s['display']),
            _str(s['state']),
            _str(s['start']),
            s['protected'] == true)
  ];
}

/// Filtered by a part of the shown or the service name; the order of the
/// other side (running first) is kept.
List<FuntiAdminService> funtiAdminServicesShown(
    List<FuntiAdminService> list, String search) {
  final needle = search.trim().toLowerCase();
  if (needle.isEmpty) return List.of(list);
  return list
      .where((s) =>
          s.display.toLowerCase().contains(needle) ||
          s.name.toLowerCase().contains(needle))
      .toList();
}

/// The list as shown: filtered by a part of the name (any case), the
/// heaviest first by processor or by memory; equal ones by name.
List<FuntiAdminProcess> funtiAdminSorted(
    List<FuntiAdminProcess> list, String search, bool byMemory) {
  final needle = search.trim().toLowerCase();
  final shown = needle.isEmpty
      ? List.of(list)
      : list.where((p) => p.name.toLowerCase().contains(needle)).toList();
  shown.sort((a, b) {
    final first = byMemory
        ? b.memory.compareTo(a.memory)
        : b.cpu.compareTo(a.cpu);
    if (first != 0) return first;
    final second = byMemory
        ? b.cpu.compareTo(a.cpu)
        : b.memory.compareTo(a.memory);
    return second != 0
        ? second
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return shown;
}
