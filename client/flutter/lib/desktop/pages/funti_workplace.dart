// FUNTIDESK (ADR-024): the administrator's workplace. Left: a narrow list of
// hosts with their type and load, read over service connections (nothing is
// shown on the host). Right: the opened hosts as tabs, each with Overview,
// Processes, Services, Autostart and Journal that work without the screen.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/funti_theme.dart';
import '../../common/widgets/funti_admin.dart';
import '../../funti/admin_rules.dart';
import '../../funti/journal_rules.dart';
import '../../funti/workplace_rules.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import '../widgets/funti_eventlog.dart';
import '../widgets/funti_family.dart';
import '../widgets/funti_journal.dart';

const _kModeOption = 'funti-workplace';
const _kEvent = 'funti_service';
const _kHandler = 'funti-workplace';

bool funtiWorkplaceOn() => bind.mainGetLocalOption(key: _kModeOption) == 'Y';

Future<void> setFuntiWorkplace(bool on) =>
    bind.mainSetLocalOption(key: _kModeOption, value: on ? 'Y' : '');

String _key(String id) => 'svc:$id';

/// "Обычный вид | Рабочее место" above the home screen.
class FuntiViewTabs extends StatelessWidget {
  final bool workplace;
  final ValueChanged<bool> onChanged;
  const FuntiViewTabs(
      {Key? key, required this.workplace, required this.onChanged})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    Widget tab(String label, bool on, bool selected) => InkWell(
          onTap: () => onChanged(on),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      width: 2,
                      color: selected ? t.accent : Colors.transparent)),
            ),
            child: Text(translate(label),
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? t.text : t.muted)),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
          color: t.chrome, border: Border(bottom: BorderSide(color: t.stroke))),
      child: Row(children: [
        tab('funti-workplace-usual', false, !workplace),
        tab('funti-workplace', true, workplace),
      ]),
    );
  }
}

/// A host of the list: the service connection state, and what is known of
/// the computer.
class _Host extends FuntiHost {
  String platform;
  bool favorite = false, family = false;
  _Host(String id, String name, this.platform) : super(id, name);
}

enum _Section { overview, processes, services, autostart, eventlog, journal }

class FuntiWorkplaceView extends StatefulWidget {
  const FuntiWorkplaceView({Key? key}) : super(key: key);

  @override
  State<FuntiWorkplaceView> createState() => _FuntiWorkplaceViewState();
}

class _FuntiWorkplaceViewState extends State<FuntiWorkplaceView> {
  final _hosts = <String, _Host>{};
  final _alerts = <FuntiAlert>[];
  final _tracker = FuntiAlertTracker();
  final _search = TextEditingController();
  final _open = <String>[];
  final _section = <String, _Section>{};
  String? _active;
  String _group = 'all';
  bool _bell = false;
  Timer? _fast, _slow, _reload;

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  void initState() {
    super.initState();
    platformFFI.registerEventHandler(_kEvent, _kHandler, _onEvent);
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    gFFI.recentPeersModel.addListener(_syncHosts);
    gFFI.favoritePeersModel.addListener(_syncHosts);
    _syncHosts();
    // The opened host is asked often, the others rarely (ADR-024).
    _fast = Timer.periodic(const Duration(seconds: 5), (_) {
      final id = _active;
      if (id != null) _ask(id, 'status');
    });
    _slow = Timer.periodic(const Duration(seconds: 30), (_) {
      for (final h in _hosts.values) {
        if (h.id != _active) _ask(h.id, 'status');
        if (h.retry) _connect(h);
      }
    });
    _reload = Timer.periodic(const Duration(seconds: 10), (_) => _syncHosts());
  }

  @override
  void dispose() {
    _fast?.cancel();
    _slow?.cancel();
    _reload?.cancel();
    gFFI.recentPeersModel.removeListener(_syncHosts);
    gFFI.favoritePeersModel.removeListener(_syncHosts);
    platformFFI.unregisterEventHandler(_kEvent, _kHandler);
    bind.mainFuntiServiceClose(id: '');
    for (final id in _hosts.keys) {
      funtiAdminForget(_key(id));
    }
    super.dispose();
  }

  String _peerName(Peer p) => p.alias.isNotEmpty
      ? p.alias
      : (p.hostname.isNotEmpty ? p.hostname : formatID(p.id));

  void _syncHosts() {
    final seen = <String>{};
    _Host host(String id, String name, String platform) {
      seen.add(id);
      final known = _hosts[id];
      if (known != null) {
        known.name = name;
        if (platform.isNotEmpty) known.platform = platform;
        return known;
      }
      final h = _Host(id, name, platform);
      _hosts[id] = h;
      _connect(h);
      return h;
    }

    for (final p in gFFI.recentPeersModel.peers) {
      host(p.id, _peerName(p), p.platform);
    }
    for (final p in gFFI.favoritePeersModel.peers) {
      host(p.id, _peerName(p), p.platform).favorite = true;
    }
    for (final m in funtiFamilyMembers()) {
      final h = _hosts[m.id] ?? host(m.id, m.title, '');
      seen.add(m.id);
      h.family = true;
    }
    if (mounted) setState(() {});
  }

  void _connect(_Host h) {
    h.onState('connecting', '');
    bind.mainFuntiServiceOpen(id: h.id);
  }

  void _ask(String id, String op) {
    if (_hosts[id]?.ready ?? false) {
      bind.mainFuntiServiceRequest(id: id, request: jsonEncode({'op': op}));
    }
  }

  Future<void> _onEvent(Map<String, dynamic> evt) async {
    final host = _hosts[evt['id']];
    if (host == null || !mounted) return;
    final alerts = <FuntiAlert>[];
    final state = evt['state'];
    if (state is String) {
      final reason = evt['reason'] is String ? evt['reason'] as String : '';
      host.onState(state, reason);
      if (state == 'ready') {
        _ask(host.id, 'status');
        _ask(host.id, 'info');
      }
      if (state == 'closed') {
        alerts.addAll(_tracker.onClosed(host, reason, _now));
      }
    }
    final result = evt['result'];
    if (result is String) {
      try {
        final answer = jsonDecode(result);
        if (answer is Map<String, dynamic>) {
          funtiAdminOnAnswer(_key(host.id), answer);
          final status = FuntiAdminStatus.parse(answer);
          if (status != null) {
            host.status = status;
            alerts.addAll(_tracker.onStatus(host, status, _now));
          }
        }
      } catch (e) {
        debugPrint('Workplace answer: $e');
      }
    }
    setState(() {
      _alerts.insertAll(0, alerts);
      if (_alerts.length > 100) _alerts.removeRange(100, _alerts.length);
    });
  }

  void _openHost(String id, [_Section section = _Section.overview]) {
    setState(() {
      if (!_open.contains(id)) _open.add(id);
      _active = id;
      _section[id] = section;
      _bell = false;
    });
    _ask(id, 'status');
  }

  void _closeHost(String id) {
    setState(() {
      _open.remove(id);
      if (_active == id) _active = _open.isEmpty ? null : _open.last;
    });
  }

  /// "Windows 11 Pro", "Linux Ubuntu 24.04", "Android" …: from the host
  /// itself when it answered, otherwise from what the peer list knows.
  String _osOf(_Host h) {
    final os = funtiAdminInfoOf(_key(h.id)).value?['os'];
    if (os is String && os.isNotEmpty) return os;
    return h.platform;
  }

  IconData _osIcon(_Host h) {
    final os = _osOf(h).toLowerCase();
    if (os.contains('android')) return Icons.phone_android;
    if (os.contains('mac')) return Icons.laptop_mac;
    if (os.contains('linux') || os.contains('ubuntu')) return Icons.terminal;
    if (os.contains('server')) return Icons.dns_outlined;
    return Icons.desktop_windows_outlined;
  }

  bool _isVm(_Host h) {
    final vm = funtiAdminInfoOf(_key(h.id)).value?['vm'];
    return vm is String && vm.isNotEmpty;
  }

  bool _inGroup(_Host h) {
    switch (_group) {
      case 'family':
        return h.family;
      case 'favorites':
        return h.favorite;
      case 'problems':
        return h.problem || !h.ready;
      default:
        return true;
    }
  }

  // --------------------------------------------------------------------
  // Left: the hosts

  Widget _meter(FuntiTokens t, String label, int percent) {
    final hot = percent > funtiAdminHot;
    final color = hot ? Theme.of(context).colorScheme.error : t.accent;
    return SizedBox(
      width: 52,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label $percent%',
            style: TextStyle(
                fontSize: 10,
                fontWeight: hot ? FontWeight.w700 : FontWeight.w400,
                color: hot ? color : t.muted)),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 3,
              backgroundColor: t.surface2,
              color: color),
        ),
      ]),
    );
  }

  Widget _tag(FuntiTokens t, String text) => Container(
        margin: const EdgeInsets.only(left: 5),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
            color: t.surface2, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 10, color: t.muted)),
      );

  Widget _hostMenu(_Host h) => PopupMenuButton<String>(
        tooltip: translate('funti-workplace-actions'),
        icon: const Icon(Icons.more_horiz, size: 18),
        onSelected: (v) {
          switch (v) {
            case 'screen':
              connect(context, h.id);
              break;
            case 'files':
              connect(context, h.id, isFileTransfer: true);
              break;
            case 'terminal':
              connect(context, h.id, isTerminal: true);
              break;
            default:
              _openHost(h.id, _Section.values.byName(v));
          }
        },
        itemBuilder: (_) => [
          for (final s in _Section.values)
            PopupMenuItem(
                value: s.name,
                child: Text(translate('funti-workplace-${s.name}'))),
          const PopupMenuDivider(),
          PopupMenuItem(
              value: 'screen', child: Text(translate('funti-workplace-screen'))),
          PopupMenuItem(
              value: 'files', child: Text(translate('funti-workplace-files'))),
          PopupMenuItem(
              value: 'terminal',
              child: Text(translate('funti-workplace-terminal'))),
        ],
      );

  Widget _hostRow(FuntiTokens t, _Host h) {
    final s = h.status;
    final selected = h.id == _active;
    final note = h.note;
    final os = _osOf(h);
    return InkWell(
      // One click opens the overview; an opened host keeps its section.
      onTap: () => _open.contains(h.id)
          ? setState(() => _active = h.id)
          : _openHost(h.id),
      child: Container(
        color: selected ? t.surface2 : null,
        padding: const EdgeInsets.fromLTRB(12, 7, 2, 7),
        child: Row(children: [
          Icon(Icons.circle,
              size: 8,
              color: h.problem
                  ? Theme.of(context).colorScheme.error
                  : (h.ready ? t.ok : t.off)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(h.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: t.text)),
                    ),
                    if (_isVm(h)) _tag(t, translate('funti-workplace-vm')),
                  ]),
                  Row(children: [
                    Icon(_osIcon(h), size: 11, color: t.muted),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                          [
                            if (os.isNotEmpty) os,
                            formatID(h.id),
                            if (note.isNotEmpty) translate(note),
                          ].join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: t.muted)),
                    ),
                  ]),
                  if (s != null) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      _meter(t, translate('funti-admin-cpu'), s.cpu),
                      const SizedBox(width: 6),
                      _meter(t, translate('funti-workplace-ram'), s.memory),
                      if (s.diskName.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _meter(t, s.diskName, s.disk),
                      ],
                    ]),
                  ],
                ]),
          ),
          _hostMenu(h),
        ]),
      ),
    );
  }

  Widget _sidebar(FuntiTokens t) {
    final shown = funtiHostsSorted(
            _hosts.values.where(_inGroup), _search.text, true)
        .cast<_Host>();
    Widget chip(String group) => Padding(
          padding: const EdgeInsets.only(right: 4, bottom: 4),
          child: ChoiceChip(
            label: Text(translate('funti-workplace-group-$group'),
                style: const TextStyle(fontSize: 11)),
            selected: _group == group,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() => _group = group),
          ),
        );
    return Container(
      width: 300,
      decoration: BoxDecoration(
          color: t.surface, border: Border(right: BorderSide(color: t.stroke))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 4),
          child: Row(children: [
            Expanded(
              child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      hintText: translate('funti-workplace-search'))),
            ),
            IconButton(
              tooltip: translate('funti-workplace-alerts'),
              onPressed: () => setState(() => _bell = !_bell),
              icon: Badge(
                isLabelVisible: _alerts.isNotEmpty,
                label: Text('${_alerts.length}'),
                child: Icon(Icons.notifications_none,
                    color: _bell ? t.accent : t.muted),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          child: Wrap(children: [
            for (final g in ['all', 'family', 'favorites', 'problems']) chip(g)
          ]),
        ),
        Divider(height: 1, color: t.rowStroke),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(translate('funti-workplace-empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.muted)),
                ))
              : ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: t.rowStroke),
                  itemBuilder: (_, i) => _hostRow(t, shown[i])),
        ),
      ]),
    );
  }

  // --------------------------------------------------------------------
  // Right: the opened hosts

  Widget _tile(FuntiTokens t, String label, String value, {bool hot = false}) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            border: Border.all(color: t.rowStroke),
            borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11, color: t.muted)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: hot ? Theme.of(context).colorScheme.error : t.text)),
        ]),
      );

  String _uptime(int seconds) {
    final d = seconds ~/ 86400, h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (d > 0) return '$d ${translate('funti-workplace-days')} $h ${translate('funti-journal-hour')}';
    if (h > 0) return '$h ${translate('funti-journal-hour')} $m ${translate('funti-journal-min')}';
    return '$m ${translate('funti-journal-min')}';
  }

  Widget _overview(FuntiTokens t, _Host h) {
    return Obx(() {
      final info = funtiAdminInfoOf(_key(h.id)).value;
      final s = h.status;
      final rows = <List<String>>[];
      String str(String k) => info?[k] is String ? info![k] as String : '';
      int number(String k) => info?[k] is int ? info![k] as int : 0;
      if (info != null) {
        rows.addAll([
          ['funti-workplace-os', str('os')],
          ['funti-workplace-hostname', str('hostname')],
          ['funti-workplace-user', str('user')],
          ['funti-workplace-uptime', number('uptime') > 0 ? _uptime(number('uptime')) : ''],
          ['funti-workplace-model', [str('maker'), str('model')].where((x) => x.isNotEmpty).join(' ')],
          ['funti-workplace-board', str('board')],
          [
            'funti-workplace-cpu',
            str('cpu').isEmpty
                ? ''
                : '${str('cpu')} · ${translate('funti-workplace-cores').replaceAll('{}', '${number('cores')}').replaceAll('{t}', '${number('threads')}')}'
          ],
          ['funti-workplace-memory', number('memory') > 0 ? readableFileSize(number('memory').toDouble()) : ''],
          [
            'funti-workplace-gpu',
            (info['gpus'] is List ? (info['gpus'] as List).whereType<String>().join(', ') : '')
          ],
          [
            'funti-workplace-disks',
            (info['disks'] is List
                ? (info['disks'] as List)
                    .whereType<Map>()
                    .map((d) => '${d['name']} ${readableFileSize(((d['size'] ?? 0) as num).toDouble())}${(d['kind'] ?? '') != '' ? ' ${d['kind']}' : ''}')
                    .join('; ')
                : '')
          ],
        ]);
      }
      final vm = str('vm');
      return ListView(padding: const EdgeInsets.all(14), children: [
        if (s != null)
          Row(children: [
            Expanded(child: _tile(t, translate('funti-workplace-cpu'), '${s.cpu}%', hot: s.cpu > funtiAdminHot)),
            const SizedBox(width: 10),
            Expanded(child: _tile(t, translate('funti-workplace-memory'), '${s.memory}%', hot: s.memory > funtiAdminHot)),
            const SizedBox(width: 10),
            Expanded(
                child: _tile(t, '${translate('funti-admin-disk')} ${s.diskName}',
                    s.diskName.isEmpty ? '—' : '${s.disk}%',
                    hot: s.disk > funtiAdminHot)),
          ]),
        const SizedBox(height: 14),
        if (vm.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(translate('funti-workplace-vm-note').replaceAll('{}', vm),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.text)),
          ),
        if (info == null)
          Text(translate('funti-admin-waiting'), style: TextStyle(color: t.muted))
        else
          for (final r in rows.where((r) => r[1].isNotEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 180,
                    child: Text(translate(r[0]),
                        style: TextStyle(fontSize: 13, color: t.muted))),
                Expanded(
                    child: SelectableText(r[1],
                        style: TextStyle(fontSize: 13, color: t.text))),
              ]),
            ),
      ]);
    });
  }

  Widget _journal(FuntiTokens t, _Host h) {
    return Obx(() {
      final events = funtiAdminJournalOf(_key(h.id)).value;
      if (events == null) {
        return Center(
            child: Text(translate('funti-admin-waiting'),
                style: TextStyle(color: t.muted)));
      }
      final rows = funtiJournalRows(events);
      if (rows.isEmpty) {
        return Center(
            child: Text(translate('funti-journal-empty'),
                style: TextStyle(color: t.muted)));
      }
      return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: t.rowStroke),
          itemBuilder: (context, i) => funtiJournalRow(context, rows[i]));
    });
  }

  bool _windows(_Host h) => _osOf(h).toLowerCase().contains('windows');

  Widget _hostPane(FuntiTokens t, _Host h) {
    final section = _section[h.id] ?? _Section.overview;
    final link = FuntiAdminLink.service(h.id);
    final sections = [
      _Section.overview,
      _Section.processes,
      if (_windows(h)) _Section.services,
      if (_windows(h)) _Section.autostart,
      if (_windows(h)) _Section.eventlog,
      _Section.journal,
    ];
    Widget body;
    if (!h.ready) {
      body = Center(
          child: Text('${h.name}: ${translate(h.note)}',
              style: TextStyle(color: t.muted)));
    } else {
      switch (section) {
        case _Section.processes:
          body = Padding(
              padding: const EdgeInsets.all(12),
              child: FuntiProcessesPanel(key: ValueKey('p${h.id}'), link: link));
          break;
        case _Section.services:
          body = Padding(
              padding: const EdgeInsets.all(12),
              child: FuntiServicesPanel(key: ValueKey('s${h.id}'), link: link));
          break;
        case _Section.autostart:
          body = Padding(
              padding: const EdgeInsets.all(12),
              child: FuntiAutostartPanel(key: ValueKey('a${h.id}'), link: link));
          break;
        case _Section.eventlog:
          body = Padding(
              padding: const EdgeInsets.all(12),
              child: FuntiEventLogPanel(key: ValueKey('e${h.id}'), link: link));
          break;
        case _Section.journal:
          body = _journal(t, h);
          break;
        case _Section.overview:
          body = _overview(t, h);
          break;
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.rowStroke))),
        child: Row(children: [
          // The sections scroll when the window is narrow; the screen
          // button stays at the right.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
          for (final s in sections)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: TextButton(
                style: TextButton.styleFrom(
                    backgroundColor: s == section ? t.surface2 : null,
                    visualDensity: VisualDensity.compact),
                onPressed: () {
                  setState(() => _section[h.id] = s);
                  if (s == _Section.journal) _ask(h.id, 'journal');
                  if (s == _Section.overview) _ask(h.id, 'info');
                },
                child: Text(translate('funti-workplace-${s.name}'),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: s == section ? FontWeight.w600 : FontWeight.w400,
                        color: s == section ? t.text : t.muted)),
              ),
            ),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
              onPressed: () => connect(context, h.id),
              icon: const Icon(Icons.desktop_windows_outlined, size: 16),
              label: Text(translate('funti-workplace-screen'))),
        ]),
      ),
      Expanded(child: body),
    ]);
  }

  Widget _main(FuntiTokens t) {
    if (_open.isEmpty || _active == null) {
      return Center(
          child: Text(translate('funti-workplace-pick'),
              textAlign: TextAlign.center, style: TextStyle(color: t.muted)));
    }
    final active = _hosts[_active]!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
            color: t.chrome, border: Border(bottom: BorderSide(color: t.stroke))),
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final id in _open)
            if (_hosts[id] != null)
              InkWell(
                onTap: () => setState(() => _active = id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                              width: 2,
                              color: id == _active ? t.accent : Colors.transparent))),
                  child: Row(children: [
                    Icon(Icons.circle,
                        size: 8, color: _hosts[id]!.ready ? t.ok : t.off),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(_hosts[id]!.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: id == _active ? FontWeight.w600 : FontWeight.w400,
                              color: id == _active ? t.text : t.muted)),
                    ),
                    IconButton(
                        tooltip: translate('Close'),
                        visualDensity: VisualDensity.compact,
                        iconSize: 14,
                        onPressed: () => _closeHost(id),
                        icon: const Icon(Icons.close)),
                  ]),
                ),
              ),
        ]),
      ),
      Expanded(child: _hostPane(t, active)),
    ]);
  }

  Widget _alertsPopup(FuntiTokens t) => Positioned(
        left: 290,
        top: 46,
        width: 360,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          color: t.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text(translate('funti-workplace-alerts'),
                            style: TextStyle(fontWeight: FontWeight.w600, color: t.text))),
                    if (_alerts.isNotEmpty)
                      TextButton(
                          onPressed: () => setState(() => _alerts.clear()),
                          child: Text(translate('funti-workplace-alerts-clear'))),
                  ]),
                  if (_alerts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(translate('funti-workplace-alerts-none'),
                          style: TextStyle(color: t.muted)),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView(shrinkWrap: true, children: [
                        for (final a in _alerts)
                          InkWell(
                            onTap: () => _openHost(a.hostId),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Text('${_clock(a.time)}  ${_alertText(a)}',
                                  style: TextStyle(fontSize: 13, color: t.text)),
                            ),
                          ),
                      ]),
                    ),
                ]),
          ),
        ),
      );

  String _alertText(FuntiAlert a) =>
      translate('funti-workplace-alert-${a.kind}')
          .replaceAll('{host}', a.hostName)
          .replaceAll('{}', '${a.value}');

  String _clock(int seconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Stack(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sidebar(t),
        Expanded(child: _main(t)),
      ]),
      if (_bell) _alertsPopup(t),
    ]);
  }
}
