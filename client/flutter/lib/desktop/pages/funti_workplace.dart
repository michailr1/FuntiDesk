// FUNTIDESK (ADR-024, stage 1): the administrator's workplace — the list of
// hosts with their state, read over service connections (no screen, nothing
// shown on the host), and alerts inside the window.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/funti_theme.dart';
import '../../funti/admin_rules.dart';
import '../../funti/workplace_rules.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import '../widgets/funti_family.dart';

const _kModeOption = 'funti-workplace';
const _kEvent = 'funti_service';
const _kHandler = 'funti-workplace';

bool funtiWorkplaceOn() => bind.mainGetLocalOption(key: _kModeOption) == 'Y';

Future<void> setFuntiWorkplace(bool on) =>
    bind.mainSetLocalOption(key: _kModeOption, value: on ? 'Y' : '');

class FuntiWorkplaceView extends StatefulWidget {
  /// Back to the usual home screen.
  final VoidCallback onLeave;
  const FuntiWorkplaceView({Key? key, required this.onLeave}) : super(key: key);

  @override
  State<FuntiWorkplaceView> createState() => _FuntiWorkplaceViewState();
}

class _FuntiWorkplaceViewState extends State<FuntiWorkplaceView> {
  final _hosts = <String, FuntiHost>{};
  final _alerts = <FuntiAlert>[];
  final _tracker = FuntiAlertTracker();
  final _search = TextEditingController();
  String? _selected;
  bool _problemsFirst = true;
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
    // The selected host is asked often, the others rarely (ADR-024).
    _fast = Timer.periodic(const Duration(seconds: 5), (_) {
      final id = _selected;
      if (id != null) _askStatus(id);
    });
    _slow = Timer.periodic(const Duration(seconds: 30), (_) {
      for (final h in _hosts.values) {
        if (h.id != _selected) _askStatus(h.id);
        if (h.retry) _open(h);
      }
    });
    // The family list is changed by the service.
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
    super.dispose();
  }

  String _peerName(Peer p) => p.alias.isNotEmpty
      ? p.alias
      : (p.hostname.isNotEmpty ? p.hostname : formatID(p.id));

  /// Favorites, family and recent computers; a service connection is tried
  /// for each, and it opens only where there is a saved password or family.
  void _syncHosts() {
    final names = <String, String>{};
    for (final p in gFFI.recentPeersModel.peers) {
      names[p.id] = _peerName(p);
    }
    for (final p in gFFI.favoritePeersModel.peers) {
      names[p.id] = _peerName(p);
    }
    for (final m in funtiFamilyMembers()) {
      names.putIfAbsent(m.id, () => m.title);
    }
    var changed = false;
    names.forEach((id, name) {
      final known = _hosts[id];
      if (known == null) {
        final host = FuntiHost(id, name);
        _hosts[id] = host;
        _open(host);
        changed = true;
      } else if (known.name != name) {
        known.name = name;
        changed = true;
      }
    });
    if (changed && mounted) setState(() {});
  }

  void _open(FuntiHost host) {
    host.onState('connecting', '');
    bind.mainFuntiServiceOpen(id: host.id);
  }

  void _askStatus(String id) {
    if (_hosts[id]?.ready ?? false) {
      bind.mainFuntiServiceRequest(id: id, request: '{"op":"status"}');
    }
  }

  Future<void> _onEvent(Map<String, dynamic> evt) async {
    final host = _hosts[evt['id']];
    if (host == null || !mounted) return;
    final state = evt['state'];
    final alerts = <FuntiAlert>[];
    if (state is String) {
      final reason = evt['reason'] is String ? evt['reason'] as String : '';
      host.onState(state, reason);
      if (state == 'ready') _askStatus(host.id);
      if (state == 'closed') alerts.addAll(_tracker.onClosed(host, reason, _now));
    }
    final result = evt['result'];
    if (result is String) {
      try {
        final status = FuntiAdminStatus.parse(jsonDecode(result));
        if (status != null) {
          host.status = status;
          alerts.addAll(_tracker.onStatus(host, status, _now));
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

  String _alertText(FuntiAlert a) =>
      translate('funti-workplace-alert-${a.kind}')
          .replaceAll('{host}', a.hostName)
          .replaceAll('{}', '${a.value}');

  String _clock(int seconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  Widget _meter(FuntiTokens t, String label, int percent) {
    final hot = percent > funtiAdminHot;
    return SizedBox(
      width: 64,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label $percent%',
            style: TextStyle(
                fontSize: 11,
                fontWeight: hot ? FontWeight.w700 : FontWeight.w400,
                color: hot ? Theme.of(context).colorScheme.error : t.muted)),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 4,
              backgroundColor: t.surface2,
              color: hot ? Theme.of(context).colorScheme.error : t.accent),
        ),
      ]),
    );
  }

  Widget _hostRow(FuntiTokens t, FuntiHost h) {
    final s = h.status;
    final selected = h.id == _selected;
    return InkWell(
      onTap: () {
        setState(() => _selected = h.id);
        _askStatus(h.id);
      },
      onDoubleTap: () => connect(context, h.id),
      child: Container(
        color: selected ? t.surface2 : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Icon(Icons.circle,
              size: 9,
              color: h.problem
                  ? Theme.of(context).colorScheme.error
                  : (h.ready ? t.ok : t.off)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(h.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: t.text)),
                  Text(
                      h.note.isEmpty
                          ? formatID(h.id)
                          : '${formatID(h.id)} · ${translate(h.note)}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: t.muted)),
                ]),
          ),
          if (s != null) ...[
            _meter(t, translate('funti-admin-cpu'), s.cpu),
            const SizedBox(width: 10),
            _meter(t, translate('funti-admin-memory'), s.memory),
            const SizedBox(width: 10),
            if (s.diskName.isNotEmpty)
              _meter(t, s.diskName, s.disk)
            else
              const SizedBox(width: 64),
          ],
        ]),
      ),
    );
  }

  Widget _details(FuntiTokens t) {
    final h = _hosts[_selected];
    if (h == null) {
      return Center(
          child: Text(translate('funti-workplace-pick'),
              style: TextStyle(color: t.muted)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(h.name,
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w600, color: t.text)),
      Text(
          h.note.isEmpty
              ? formatID(h.id)
              : '${formatID(h.id)} · ${translate(h.note)}',
          style: TextStyle(fontSize: 13, color: t.muted)),
      const SizedBox(height: 14),
      Wrap(spacing: 10, runSpacing: 8, children: [
        ElevatedButton(
            onPressed: () => connect(context, h.id),
            child: Text(translate('funti-workplace-screen'))),
        OutlinedButton(
            onPressed: () => connect(context, h.id, isFileTransfer: true),
            child: Text(translate('funti-workplace-files'))),
        OutlinedButton(
            onPressed: () => connect(context, h.id, isTerminal: true),
            child: Text(translate('funti-workplace-terminal'))),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final shown = funtiHostsSorted(_hosts.values, _search.text, _problemsFirst);
    Widget card(Widget child) => Container(
          decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.stroke)),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(translate('funti-workplace'),
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600, color: t.text)),
          const Spacer(),
          TextButton(
              onPressed: widget.onLeave,
              child: Text(translate('funti-workplace-leave'))),
        ]),
        const SizedBox(height: 10),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 520,
              child: card(Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
                  child: Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                                isDense: true,
                                prefixIcon: const Icon(Icons.search, size: 18),
                                hintText:
                                    translate('funti-workplace-search')))),
                    Tooltip(
                      message: translate('funti-workplace-problems-first'),
                      child: IconButton(
                          icon: Icon(Icons.warning_amber_rounded,
                              color: _problemsFirst ? t.accent : t.muted),
                          onPressed: () => setState(
                              () => _problemsFirst = !_problemsFirst)),
                    ),
                  ]),
                ),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text(translate('funti-workplace-empty'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: t.muted)))
                      : ListView.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, __) =>
                              Divider(height: 1, color: t.rowStroke),
                          itemBuilder: (_, i) => _hostRow(t, shown[i])),
                ),
              ])),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    card(Padding(
                        padding: const EdgeInsets.all(20),
                        child: SizedBox(height: 130, child: _details(t)))),
                    const SizedBox(height: 16),
                    Expanded(
                      child: card(Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                              child: Row(children: [
                                Expanded(
                                    child: Text(
                                        translate('funti-workplace-alerts'),
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: t.text))),
                                if (_alerts.isNotEmpty)
                                  TextButton(
                                      onPressed: () =>
                                          setState(() => _alerts.clear()),
                                      child: Text(translate(
                                          'funti-workplace-alerts-clear'))),
                              ]),
                            ),
                            Expanded(
                              child: _alerts.isEmpty
                                  ? Center(
                                      child: Text(
                                          translate(
                                              'funti-workplace-alerts-none'),
                                          style: TextStyle(color: t.muted)))
                                  : ListView(
                                      padding: const EdgeInsets.fromLTRB(
                                          20, 0, 20, 12),
                                      children: [
                                          for (final a in _alerts)
                                            InkWell(
                                              onTap: () => setState(
                                                  () => _selected = a.hostId),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 4),
                                                child: Text(
                                                    '${_clock(a.time)}  ${_alertText(a)}',
                                                    style: TextStyle(
                                                        fontSize: 13,
                                                        color: t.text)),
                                              ),
                                            )
                                        ]),
                            ),
                          ])),
                    ),
                  ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
