// FUNTIDESK (ADR-009/010): account copies have no connection or pairing actions.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../models/platform_model.dart';

abstract class _AccountState<T extends StatefulWidget> extends State<T> {
  Timer? _timer;
  Map<String, dynamic> snapshot = {};
  bool busy = false;
  bool _reading = false;
  String localError = '';

  @override
  void initState() {
    super.initState();
    readStatus();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => readStatus());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Map<String, dynamic> get data => snapshot['data'] is Map
      ? Map<String, dynamic>.from(snapshot['data'])
      : {};
  bool get loggedIn => snapshot['logged_in'] == true;
  String get error =>
      localError.isNotEmpty ? localError : snapshot['error'] as String? ?? '';

  Future<void> readStatus() async {
    if (_reading || !isWindows) return;
    _reading = true;
    try {
      final raw = await bind.mainFuntiAccount(action: 'status', payload: '{}');
      final value = Map<String, dynamic>.from(jsonDecode(raw));
      if (mounted) {
        setState(() {
          snapshot = value;
          if (localError == 'funti-account-service-unavailable')
            localError = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => localError = 'funti-account-service-unavailable');
      }
    } finally {
      _reading = false;
    }
  }

  Future<bool> command(String action,
      [Map<String, dynamic> payload = const {}]) async {
    if (busy) return false;
    setState(() {
      busy = true;
      localError = '';
    });
    try {
      final raw = await bind.mainFuntiAccount(
          action: action, payload: jsonEncode(payload));
      final result = Map<String, dynamic>.from(jsonDecode(raw));
      if (!mounted) return false;
      setState(() {
        if (result.containsKey('logged_in')) snapshot = result;
        localError = result['error'] as String? ?? '';
      });
      await readStatus();
      return localError.isEmpty;
    } catch (_) {
      if (mounted) {
        setState(() => localError = 'funti-account-service-unavailable');
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

String _date(dynamic value) {
  if (value is! num || value <= 0) return translate('funti-account-no-report');
  final date =
      DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year} ${two(date.hour)}:${two(date.minute)}';
}

List<Map<String, dynamic>> _rows(dynamic value) => value is List
    ? value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList()
    : [];

class FuntiAccountPanel extends StatefulWidget {
  const FuntiAccountPanel({Key? key, this.compact = false, this.onOpen})
      : super(key: key);
  final bool compact;
  final VoidCallback? onOpen;

  @override
  State<FuntiAccountPanel> createState() => _FuntiAccountPanelState();
}

class _FuntiAccountPanelState extends _AccountState<FuntiAccountPanel> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final Map<String, String> _removeRequests = {};

  @override
  void dispose() {
    _email.clear();
    _code.clear();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _remove(Map<String, dynamic> member) async {
    final pk = member['pk'] as String?;
    if (pk == null || busy) return;
    final name =
        member['name'] as String? ?? translate('funti-account-computer');
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(translate('funti-account-remove-title')),
              content:
                  Text('$name\n\n${translate('funti-account-remove-confirm')}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(translate('Cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(translate('funti-account-remove'))),
              ],
            ));
    if (confirmed != true || !mounted) return;
    final request = _removeRequests.putIfAbsent(pk, () {
      final random = Random.secure();
      return List.generate(
              32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
    });
    if (await command('remove', {'target_pk': pk, 'request_id': request})) {
      _removeRequests.remove(pk);
    }
  }

  Future<void> _logout(bool all) async {
    if (all) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(translate('funti-account-logout-all')),
                content: Text(translate('funti-account-logout-confirm')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(translate('Cancel'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(translate('funti-account-logout-all'))),
                ],
              ));
      if (confirmed != true || !mounted) return;
    }
    if (await command(all ? 'logout_all' : 'logout')) {
      _email.clear();
      _code.clear();
      _removeRequests.clear();
    }
  }

  Widget _heading(String key) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Text(translate(key),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      );

  Widget _member(Map<String, dynamic> member, {bool device = false}) => Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Icon(Icons.computer_outlined),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        member['name'] as String? ??
                            translate('funti-account-computer'),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    SelectableText(
                        'ID: ${member[device ? 'funti_id' : 'id'] ?? ''}'),
                    if (device)
                      Text(
                          '${translate('funti-account-last-exchange')}: ${_date(member['last_seen'])}',
                          style:
                              TextStyle(color: FuntiTokens.of(context).muted)),
                  ])),
              if (!widget.compact)
                TextButton(
                    onPressed: busy ? null : () => _remove(member),
                    child: Text(translate('funti-account-remove'))),
            ])),
      );

  List<Widget> _deliveries(List<Map<String, dynamic>> devices) {
    final rows = _rows(data['deliveries']);
    if (rows.isEmpty) return [Text(translate('funti-account-no-removals'))];
    final groups = <dynamic, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      groups.putIfAbsent(row['event_id'], () => []).add(row);
    }
    final names = {
      for (final device in devices) device['device_id']: device['name']
    };
    return groups.values.map((group) {
      final done = group.where((row) => row['acknowledged_at'] != null).length;
      return Card(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${translate('funti-account-removal-from')} ${_date(group.first['created_at'])}'),
                  Text(
                      '${translate('funti-account-confirmed')}: $done / ${group.length} ${translate('funti-account-shown-computers')}'),
                  for (final row in group)
                    Text(
                        '${names[row['source_device_id']] ?? translate('funti-account-computer')}: ${row['acknowledged_at'] == null ? translate('funti-account-pending') : _date(row['acknowledged_at'])}'),
                ],
              )));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final devices = _rows(data['devices']);
    final sources = _rows(data['sources']);
    final needsCode = snapshot['needs_code'] == true;
    final session = data['session'] is Map ? data['session'] as Map : {};
    return SingleChildScrollView(
        child: Padding(
      padding: EdgeInsets.all(widget.compact ? 16 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!widget.compact) ...[
          Text(translate('funti-account-title'),
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(translate('funti-account-description'),
              style: TextStyle(color: t.muted)),
        ],
        if (busy)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator()),
        if (error.isNotEmpty)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(translate(error),
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (!loggedIn) ...[
          const SizedBox(height: 16),
          if (widget.compact) ...[
            Text(translate('funti-account-signin-tip')),
            TextButton(
                onPressed: widget.onOpen,
                child: Text(translate('funti-account-open'))),
          ] else ...[
            TextField(
                controller: _email,
                enabled: !busy && !needsCode,
                keyboardType: TextInputType.emailAddress,
                maxLength: 254,
                decoration: InputDecoration(
                    labelText: translate('funti-account-email'))),
            if (needsCode) ...[
              Text(translate('funti-account-code-sent'),
                  style: TextStyle(color: t.muted)),
              TextField(
                  controller: _code,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  decoration: InputDecoration(
                      labelText: translate('funti-account-code'))),
              FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final code = _code.text.trim();
                          _code.clear();
                          await command('verify', {'code': code});
                        },
                  child: Text(translate('funti-account-signin'))),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: busy
                    ? null
                    : () => command('request', {'email': _email.text.trim()}),
                child: Text(translate(needsCode
                    ? 'funti-account-resend'
                    : 'funti-account-send-code'))),
          ],
        ] else ...[
          if (!widget.compact) ...[
            const SizedBox(height: 16),
            SelectableText(session['email'] as String? ??
                translate('funti-account-signed-in')),
            Text(
                '${translate('funti-account-expires')}: ${_date(session['expires_at'])}',
                style: TextStyle(color: t.muted)),
            Wrap(spacing: 12, children: [
              TextButton(
                  onPressed: busy ? null : () => command('refresh'),
                  child: Text(translate('funti-account-refresh'))),
              TextButton(
                  onPressed: busy ? null : () => _logout(false),
                  child: Text(translate('funti-account-logout'))),
              TextButton(
                  onPressed: busy ? null : () => _logout(true),
                  child: Text(translate('funti-account-logout-all'))),
            ]),
          ],
          Text(
              '${translate('funti-account-updated')}: ${_date(snapshot['last_refresh'])}',
              style: TextStyle(color: t.muted)),
          _heading('funti-account-devices'),
          if (devices.isEmpty) Text(translate('funti-account-no-devices')),
          for (final device in devices) _member(device, device: true),
          if (widget.compact)
            TextButton(
                onPressed: widget.onOpen,
                child: Text(translate('funti-account-open')))
          else ...[
            _heading('funti-account-family-copies'),
            Text(translate('funti-account-copy-tip'),
                style: TextStyle(color: t.muted)),
            if (sources.isEmpty) Text(translate('funti-account-no-copies')),
            for (final source in sources) ...[
              const SizedBox(height: 12),
              Text(source['source_name'] as String? ??
                  translate('funti-account-computer')),
              Text(
                  '${translate('funti-account-copy-from')}: ${_date(source['updated_at'])}',
                  style: TextStyle(color: t.muted)),
              for (final member in _rows(source['members'])) _member(member),
            ],
            _heading('funti-account-removals'),
            if (data['has_more'] == true)
              Text(translate('funti-account-partial-log'),
                  style: TextStyle(color: t.muted)),
            ..._deliveries(devices),
          ],
        ],
        if (!widget.compact && snapshot['bound'] == true)
          Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(translate('funti-account-delivery-tip'),
                  style: TextStyle(color: t.muted))),
      ]),
    ));
  }
}

class FuntiAccountNotice extends StatefulWidget {
  const FuntiAccountNotice({Key? key}) : super(key: key);
  @override
  State<FuntiAccountNotice> createState() => _FuntiAccountNoticeState();
}

class _FuntiAccountNoticeState extends _AccountState<FuntiAccountNotice> {
  @override
  Widget build(BuildContext context) {
    final notices = _rows(snapshot['notices']);
    if (notices.isEmpty) return const SizedBox.shrink();
    final removed = notices.any((n) => n['kind'] == 'remove');
    final logged = notices.any((n) => n['kind'] == 'login');
    final t = FuntiTokens.of(context);
    return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: t.surface2, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(Icons.info_outline, color: t.accent),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                if (removed) Text(translate('funti-account-removal-notice')),
                if (logged) Text(translate('funti-account-login-notice')),
              ])),
          TextButton(
              onPressed: busy ? null : () => command('dismiss'),
              child: Text(translate('funti-account-dismiss'))),
        ]));
  }
}
