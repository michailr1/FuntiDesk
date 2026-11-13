// FUNTIDESK (ADR-024): the administrator's workplace — the state of a host
// in the list, the order of the list and the alerts shown in the window.
// No Flutter imports: checked by scripts/ci/test-funti-dart.sh.

import 'admin_rules.dart';

/// Why a service connection is not open.
const funtiServiceNoAccess = 'funti-service-no-access';
const funtiServiceOld = 'funti-service-old-version';
const funtiServiceOffline = 'funti-service-offline';
const funtiServiceRefused = 'funti-service-refused';

class FuntiHost {
  final String id;
  String name;

  /// "idle", "connecting", "ready" or "closed".
  String state = 'idle';

  /// For "closed": a reason of the list above, or a login error text.
  String reason = '';
  FuntiAdminStatus? status;

  /// What needs attention on it (antivirus, updates, restart …): the
  /// `items` of the `attention` answer.
  List<Map<String, dynamic>> attention = const [];

  FuntiHost(this.id, this.name);

  bool get ready => state == 'ready';
  bool get problem =>
      ready && ((status?.hot ?? false) || attention.isNotEmpty);

  /// Trying again makes sense only for a host that was not reachable.
  bool get retry => state == 'closed' && reason == funtiServiceOffline;

  /// What to show instead of the numbers; empty when they are shown.
  String get note {
    if (ready) return '';
    if (state == 'connecting' || state == 'idle') return 'funti-workplace-connecting';
    switch (reason) {
      case funtiServiceOffline:
        return 'funti-service-offline';
      case funtiServiceOld:
        return 'funti-service-old-version';
      case funtiServiceNoAccess:
      case funtiServiceRefused:
      case 'Wrong Password':
        return 'funti-workplace-no-access';
      default:
        return 'funti-workplace-no-connection';
    }
  }

  void onState(String newState, String newReason) {
    state = newState;
    reason = newReason;
    if (!ready) {
      status = null;
      attention = const [];
    }
  }
}

/// With [problemsFirst]: overloaded hosts, then the other connected ones,
/// then the rest; by name inside each group. Otherwise by name only.
List<FuntiHost> funtiHostsSorted(
    Iterable<FuntiHost> hosts, String search, bool problemsFirst) {
  final needle = search.trim().toLowerCase();
  final shown = hosts
      .where((h) =>
          needle.isEmpty ||
          h.name.toLowerCase().contains(needle) ||
          h.id.contains(needle))
      .toList();
  int rank(FuntiHost h) => h.problem ? 0 : (h.ready ? 1 : 2);
  shown.sort((a, b) {
    if (problemsFirst && rank(a) != rank(b)) return rank(a) - rank(b);
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  return shown;
}

class FuntiAlert {
  /// "disk", "memory" or "lost".
  final String kind;
  final String hostId;
  final String hostName;
  final int time;

  /// Percent for "disk" and "memory".
  final int value;
  FuntiAlert(this.kind, this.hostId, this.hostName, this.time, this.value);
}

/// Turns what is seen of the hosts into alerts: one when a condition
/// starts, and again only after it has gone away.
class FuntiAlertTracker {
  /// Memory has to stay above the threshold this long (seconds).
  final int memorySeconds;
  final int threshold;
  FuntiAlertTracker({this.memorySeconds = 180, this.threshold = funtiAdminHot});

  final _diskOn = <String>{};
  final _memorySince = <String, int>{};
  final _memoryOn = <String>{};
  final _wasReady = <String>{};

  /// A new status of [host] at [now] (seconds).
  List<FuntiAlert> onStatus(FuntiHost host, FuntiAdminStatus s, int now) {
    final alerts = <FuntiAlert>[];
    _wasReady.add(host.id);
    if (s.diskName.isNotEmpty && s.disk > threshold) {
      if (_diskOn.add(host.id)) {
        alerts.add(FuntiAlert('disk', host.id, host.name, now, s.disk));
      }
    } else {
      _diskOn.remove(host.id);
    }
    if (s.memory > threshold) {
      final since = _memorySince.putIfAbsent(host.id, () => now);
      if (now - since >= memorySeconds && _memoryOn.add(host.id)) {
        alerts.add(FuntiAlert('memory', host.id, host.name, now, s.memory));
      }
    } else {
      _memorySince.remove(host.id);
      _memoryOn.remove(host.id);
    }
    return alerts;
  }

  /// The connection to [host] ended at [now]: an alert only if the host
  /// was connected before and is not reachable any more.
  List<FuntiAlert> onClosed(FuntiHost host, String reason, int now) {
    _memorySince.remove(host.id);
    if (reason != funtiServiceOffline || !_wasReady.remove(host.id)) return [];
    return [FuntiAlert('lost', host.id, host.name, now, 0)];
  }
}

/// The items of an `attention` answer.
List<Map<String, dynamic>> funtiAttentionItems(Map<String, dynamic> answer) {
  final items = answer['items'];
  if (items is! List) return const [];
  return [
    for (final i in items)
      if (i is Map && i['kind'] is String) Map<String, dynamic>.from(i)
  ];
}
