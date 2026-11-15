// FUNTIDESK (ADR-026, stage 1): the administrator's workplace on a phone —
// the list of computers with their load and problems, and a computer with
// the same sections as on the desktop, laid out for a narrow screen. The
// data comes over service connections (ADR-024), as on the desktop.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/funti_theme.dart';
import '../../common/widgets/funti_admin.dart';
import '../../desktop/widgets/funti_eventlog.dart';
import '../../desktop/widgets/funti_family.dart';
import '../../desktop/widgets/funti_history.dart';
import '../../desktop/widgets/funti_journal.dart';
import '../../funti/admin_rules.dart';
import '../../funti/history_rules.dart';
import '../../funti/journal_rules.dart';
import '../../funti/workplace_rules.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

const _kEvent = 'funti_service';
const _kHandler = 'funti-workplace-mobile';

String _key(String id) => 'svc:$id';

class _MHost extends FuntiHost {
  String platform;
  FuntiHistory? history;
  _MHost(String id, String name, this.platform) : super(id, name);
}

/// The hosts and their service connections, shared by the list and the
/// computer pages while the tab lives.
class _Workplace extends ChangeNotifier {
  final hosts = <String, _MHost>{};
  Timer? _poll;

  void start() {
    platformFFI.registerEventHandler(_kEvent, _kHandler, _onEvent);
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    gFFI.recentPeersModel.addListener(sync);
    gFFI.favoritePeersModel.addListener(sync);
    sync();
    var tick = 0;
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      tick++;
      for (final h in hosts.values) {
        ask(h.id, 'status');
        if (tick % 20 == 0) ask(h.id, 'attention');
        if (h.retry) _connect(h);
      }
    });
  }

  void stop() {
    _poll?.cancel();
    gFFI.recentPeersModel.removeListener(sync);
    gFFI.favoritePeersModel.removeListener(sync);
    platformFFI.unregisterEventHandler(_kEvent, _kHandler);
    bind.mainFuntiServiceClose(id: '');
  }

  void sync() {
    void add(String id, String name, String platform) {
      final known = hosts[id];
      if (known != null) {
        known.name = name;
        if (platform.isNotEmpty) known.platform = platform;
        return;
      }
      final h = _MHost(id, name, platform);
      hosts[id] = h;
      _connect(h);
    }

    String name(dynamic p) => p.alias.isNotEmpty
        ? p.alias
        : (p.hostname.isNotEmpty ? p.hostname : formatID(p.id));
    for (final p in gFFI.recentPeersModel.peers) {
      add(p.id, name(p), p.platform);
    }
    for (final p in gFFI.favoritePeersModel.peers) {
      add(p.id, name(p), p.platform);
    }
    for (final m in funtiFamilyMembers()) {
      add(m.id, m.title, '');
    }
    notifyListeners();
  }

  void _connect(_MHost h) {
    h.onState('connecting', '');
    bind.mainFuntiServiceOpen(id: h.id);
  }

  void ask(String id, String op, [Map<String, dynamic>? more]) {
    if (hosts[id]?.ready ?? false) {
      bind.mainFuntiServiceRequest(
          id: id, request: jsonEncode({'op': op, ...?more}));
    }
  }

  Future<void> _onEvent(Map<String, dynamic> evt) async {
    final h = hosts[evt['id']];
    if (h == null) return;
    final state = evt['state'];
    if (state is String) {
      h.onState(state, evt['reason'] is String ? evt['reason'] as String : '');
      if (state == 'ready') {
        ask(h.id, 'status');
        ask(h.id, 'info');
        ask(h.id, 'attention');
      }
    }
    final result = evt['result'];
    if (result is String) {
      try {
        final a = jsonDecode(result);
        if (a is Map<String, dynamic>) {
          if (a['op'] == 'history') {
            h.history = funtiHistory(a);
          } else {
            funtiAdminOnAnswer(_key(h.id), a);
            if (a['op'] == 'attention') h.attention = funtiAttentionItems(a);
            final status = FuntiAdminStatus.parse(a);
            if (status != null) h.status = status;
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  String osOf(_MHost h) {
    final os = funtiAdminInfoOf(_key(h.id)).value?['os'];
    return os is String && os.isNotEmpty ? os : h.platform;
  }

  bool windows(_MHost h) => osOf(h).toLowerCase().contains('windows');
}

class FuntiWorkplaceMobilePage extends StatefulWidget implements PageShape {
  FuntiWorkplaceMobilePage({Key? key}) : super(key: key);

  @override
  final title = translate('funti-workplace');

  @override
  final icon = const Icon(Icons.dashboard_outlined);

  @override
  final List<Widget> appBarActions = const [];

  @override
  State<FuntiWorkplaceMobilePage> createState() => _FuntiWorkplaceMobilePageState();
}

class _FuntiWorkplaceMobilePageState extends State<FuntiWorkplaceMobilePage> {
  final _w = _Workplace();
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _w.start();
    _w.addListener(_changed);
  }

  @override
  void dispose() {
    _w.removeListener(_changed);
    _w.stop();
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Widget _meters(FuntiTokens t, FuntiAdminStatus s) => Text(
      '${translate('funti-admin-cpu')} ${s.cpu}% · ${translate('funti-workplace-ram')} ${s.memory}%'
      '${s.diskName.isEmpty ? '' : ' · ${s.diskName} ${s.disk}%'}',
      style: TextStyle(fontSize: 12, color: s.hot ? Theme.of(context).colorScheme.error : t.muted));

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final hosts = funtiHostsSorted(_w.hosts.values, _search.text, true).cast<_MHost>();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: translate('funti-workplace-search')),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async => _w.sync(),
          child: ListView.separated(
            itemCount: hosts.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: t.rowStroke),
            itemBuilder: (context, i) {
              final h = hosts[i];
              final os = _w.osOf(h);
              return ListTile(
                leading: Icon(Icons.circle,
                    size: 10,
                    color: h.problem
                        ? Theme.of(context).colorScheme.error
                        : (h.ready ? t.ok : t.off)),
                title: Text(h.name, overflow: TextOverflow.ellipsis),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      [if (os.isNotEmpty) os, formatID(h.id), if (h.note.isNotEmpty) translate(h.note)]
                          .join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: t.muted)),
                  if (h.status != null) _meters(t, h.status!),
                ]),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => _HostPage(workplace: _w, host: h))),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

class _HostPage extends StatefulWidget {
  final _Workplace workplace;
  final _MHost host;
  const _HostPage({required this.workplace, required this.host});

  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage> {
  _MHost get h => widget.host;
  _Workplace get w => widget.workplace;
  int _days = 1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    w.addListener(_changed);
    w.ask(h.id, 'info');
    w.ask(h.id, 'attention');
    w.ask(h.id, 'hardware');
    w.ask(h.id, 'history', {'days': _days});
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => w.ask(h.id, 'status'));
  }

  @override
  void dispose() {
    _timer?.cancel();
    w.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Widget _overview(FuntiTokens t) {
    return Obx(() {
      final info = funtiAdminInfoOf(_key(h.id)).value;
      String str(String k) => info?[k] is String ? info![k] as String : '';
      final s = h.status;
      final error = Theme.of(context).colorScheme.error;
      final rows = <List<String>>[
        ['funti-workplace-os', str('os')],
        ['funti-workplace-hostname', str('hostname')],
        ['funti-workplace-user', str('user')],
        ['funti-workplace-model', [str('maker'), str('model')].where((x) => x.isNotEmpty).join(' ')],
        ['funti-workplace-cpu', str('cpu')],
        [
          'funti-workplace-memory',
          info?['memory'] is num ? readableFileSize((info!['memory'] as num).toDouble()) : ''
        ],
      ];
      return ListView(padding: const EdgeInsets.all(14), children: [
        if (s != null)
          Text(
              '${translate('funti-workplace-cpu')} ${s.cpu}% · ${translate('funti-workplace-memory')} ${s.memory}%'
              '${s.diskName.isEmpty ? '' : ' · ${s.diskName} ${s.disk}%'}',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text)),
        const SizedBox(height: 12),
        Text(translate('funti-attention-title'),
            style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
        const SizedBox(height: 4),
        if (h.attention.isEmpty)
          Text(translate('funti-attention-none'), style: TextStyle(color: t.muted))
        else
          for (final i in h.attention)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(i['level'] == 'error' ? Icons.error_outline : Icons.warning_amber_rounded,
                    size: 16, color: i['level'] == 'error' ? error : Colors.amber),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(translate('funti-attention-${i['kind']}')
                        .replaceAll('{}', '${i['detail'] ?? ''}'))),
              ]),
            ),
        const SizedBox(height: 12),
        for (final r in rows.where((r) => r[1].isNotEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(translate(r[0]), style: TextStyle(fontSize: 12, color: t.muted)),
              SelectableText(r[1], style: TextStyle(color: t.text)),
            ]),
          ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: Text(translate('funti-history-title'),
                  style: TextStyle(fontWeight: FontWeight.w600, color: t.text))),
          for (final d in [1, 7])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ChoiceChip(
                  label: Text(translate('funti-history-days-$d')),
                  selected: _days == d,
                  onSelected: (_) {
                    setState(() {
                      _days = d;
                      h.history = null;
                    });
                    w.ask(h.id, 'history', {'days': d});
                  }),
            ),
        ]),
        const SizedBox(height: 8),
        if (h.history == null)
          Text(translate('funti-admin-waiting'), style: TextStyle(color: t.muted))
        else if (h.history!.points.isEmpty)
          Text(translate('funti-history-empty'), style: TextStyle(color: t.muted))
        else
          FuntiHistoryChart(history: h.history!),
      ]);
    });
  }

  Widget _journal(FuntiTokens t) {
    return Obx(() {
      final events = funtiAdminJournalOf(_key(h.id)).value;
      if (events == null) {
        return Center(child: Text(translate('funti-admin-waiting')));
      }
      final rows = funtiJournalRows(events);
      return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: t.rowStroke),
          itemBuilder: (context, i) => funtiJournalRow(context, rows[i]));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final link = FuntiAdminLink.service(h.id);
    final windows = w.windows(h);
    final tabs = <(String, Widget Function())>[
      ('funti-workplace-overview', () => _overview(t)),
      ('funti-workplace-processes', () => FuntiProcessesPanel(link: link)),
      if (windows) ('funti-workplace-services', () => FuntiServicesPanel(link: link)),
      if (windows) ('funti-workplace-autostart', () => FuntiAutostartPanel(link: link)),
      if (windows) ('funti-workplace-programs', () => FuntiProgramsPanel(link: link)),
      ('funti-workplace-disk', () => FuntiFoldersPanel(link: link)),
      if (windows) ('funti-workplace-eventlog', () => FuntiEventLogPanel(link: link)),
      ('funti-workplace-journal', () => _journal(t)),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(h.name),
          actions: [
            IconButton(
                tooltip: translate('funti-workplace-screen'),
                onPressed: () => connect(context, h.id),
                icon: const Icon(Icons.desktop_windows_outlined)),
          ],
          bottom: TabBar(
            isScrollable: true,
            onTap: (i) {
              if (tabs[i].$1 == 'funti-workplace-journal') w.ask(h.id, 'journal');
            },
            tabs: [for (final tab in tabs) Tab(text: translate(tab.$1))],
          ),
        ),
        body: !h.ready
            ? Center(child: Text(translate(h.note.isEmpty ? 'funti-admin-waiting' : h.note)))
            : TabBarView(children: [
                for (final tab in tabs)
                  Padding(padding: const EdgeInsets.all(8), child: tab.$2()),
              ]),
      ),
    );
  }
}
