// FUNTIDESK (ADR-024, stage 5): Windows event logs of the other computer —
// "System", "Application", "Security", by level, with a text filter.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../common/widgets/funti_admin.dart';
import '../../funti/eventlog_rules.dart';

const _logs = ['System', 'Application', 'Security'];
const _levels = ['all', 'warning', 'error'];
const _count = 300;

class FuntiEventLogPanel extends StatefulWidget {
  final FuntiAdminLink link;
  const FuntiEventLogPanel({Key? key, required this.link}) : super(key: key);

  @override
  State<FuntiEventLogPanel> createState() => _FuntiEventLogPanelState();
}

class _FuntiEventLogPanelState extends State<FuntiEventLogPanel> {
  String _log = 'System';
  String _level = 'error';
  final _filter = TextEditingController();
  final _expanded = <int>{};

  Rxn<Map<String, dynamic>> get _answer =>
      funtiAdminEventLogOf(widget.link.key);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _load() {
    _answer.value = null;
    _expanded.clear();
    widget.link
        .ask({'op': 'eventlog', 'log': _log, 'level': _level, 'count': _count});
  }

  String _time(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _icon(BuildContext context, FuntiTokens t, FuntiEvent e) {
    final error = Theme.of(context).colorScheme.error;
    if (e.failure) return Icon(Icons.lock_outline, size: 16, color: error);
    if (e.level == 1) return Icon(Icons.dangerous_outlined, size: 16, color: error);
    if (e.level == 2) return Icon(Icons.error_outline, size: 16, color: error);
    if (e.warning) {
      return const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber);
    }
    return Icon(Icons.info_outline, size: 16, color: t.muted);
  }

  Widget _row(BuildContext context, FuntiTokens t, int i, FuntiEvent e) {
    final open = _expanded.contains(i);
    return InkWell(
      onTap: () => setState(() => open ? _expanded.remove(i) : _expanded.add(i)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _icon(context, t, e),
            const SizedBox(width: 8),
            SizedBox(
                width: 104,
                child: Text(_time(e.time),
                    style: TextStyle(fontSize: 12, color: t.muted))),
            SizedBox(
                width: 200,
                child: Text(e.source,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.text))),
            SizedBox(
                width: 56,
                child: Text('${e.id}',
                    style: TextStyle(fontSize: 12, color: t.muted))),
            Expanded(
                child: Text(e.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.text))),
          ]),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 6, 4),
              child: SelectableText(
                  e.message.isEmpty
                      ? translate('funti-eventlog-no-text')
                      : e.message,
                  style: TextStyle(fontSize: 12, color: t.text)),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final l in _logs)
              ChoiceChip(
                  label: Text(translate('funti-eventlog-$l')),
                  selected: _log == l,
                  onSelected: (_) {
                    setState(() => _log = l);
                    _load();
                  }),
            const SizedBox(width: 8),
            DropdownButton<String>(
                value: _level,
                underline: const SizedBox.shrink(),
                items: [
                  for (final l in _levels)
                    DropdownMenuItem(
                        value: l,
                        child: Text(translate('funti-eventlog-level-$l')))
                ],
                onChanged: (l) {
                  if (l == null) return;
                  setState(() => _level = l);
                  _load();
                }),
            SizedBox(
              width: 220,
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: translate('funti-eventlog-filter')),
              ),
            ),
            IconButton(
                tooltip: translate('Refresh'),
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18)),
          ]),
      const SizedBox(height: 8),
      Expanded(child: Obx(() {
        final answer = _answer.value;
        if (answer == null ||
            answer['error'] == null &&
                (answer['log'] != _log || answer['level'] != _level)) {
          return Center(
              child: Text(translate('funti-admin-waiting'),
                  style: TextStyle(color: t.muted)));
        }
        final error = answer['error'];
        if (error is String) {
          return Center(
              child: Text(translate(error), style: TextStyle(color: t.muted)));
        }
        final all = funtiEvents(answer);
        final shown = all.where((e) => e.matches(_filter.text)).toList();
        if (shown.isEmpty) {
          return Center(
              child: Text(translate('funti-eventlog-empty'),
                  style: TextStyle(color: t.muted)));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView.separated(
                itemCount: shown.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: t.rowStroke),
                itemBuilder: (context, i) => _row(context, t, i, shown[i])),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                translate('funti-eventlog-shown')
                    .replaceAll('{}', '${shown.length}')
                    .replaceAll('{n}', '${all.length}'),
                style: TextStyle(fontSize: 12, color: t.muted)),
          ),
        ]);
      })),
    ]);
  }
}
