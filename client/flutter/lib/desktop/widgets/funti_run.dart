// FUNTIDESK (ADR-024, stage 7): a command or script on several computers of
// the workplace — choose the computers, confirm, see every answer.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../funti/run_rules.dart';
import 'funti_bulk_send.dart';

/// A computer the command can go to.
class FuntiRunHost {
  final String id, name;

  /// Empty when the command can go there; otherwise why not.
  final String note;
  const FuntiRunHost(this.id, this.name, this.note);
}

/// The runs of this window, kept while the workplace is open.
class FuntiRunBoard extends ChangeNotifier {
  final runs = <FuntiRun>[];

  void onAnswer(String hostId, Map<String, dynamic> answer) {
    for (final r in runs) {
      if (r.onAnswer(hostId, answer)) {
        notifyListeners();
        return;
      }
    }
  }

  /// An answer made here (file sending), not by the other computer.
  void localAnswer(FuntiRun run, String hostId, Map<String, dynamic> a) {
    run.results[hostId]?.onAnswer(a);
    notifyListeners();
  }

  void add(FuntiRun run) {
    runs.insert(0, run);
    if (runs.length > 20) runs.removeLast();
    notifyListeners();
  }
}

const _timeouts = [30, 60, 300, 600];

/// Ready-made group actions: (translation key, shell, script).
const _presets = [
  ('funti-run-preset-restart', 'cmd',
      'shutdown /r /t 60 /c "FuntiDesk: перезагрузка через 1 минуту. Сохраните работу."'),
  ('funti-run-preset-shutdown', 'cmd',
      'shutdown /s /t 60 /c "FuntiDesk: выключение через 1 минуту. Сохраните работу."'),
  ('funti-run-preset-cancel', 'cmd', 'shutdown /a'),
  ('funti-run-preset-gpupdate', 'cmd', 'gpupdate /force'),
  ('funti-run-preset-temp', 'powershell',
      r"Get-ChildItem $env:windir\Temp, 'C:\Users\*\AppData\Local\Temp' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; 'done'"),
  ('funti-run-preset-ip', 'powershell',
      'Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.IPAddress -ne "127.0.0.1" } | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String'),
  ('funti-run-preset-sessions', 'cmd', 'query user'),
];

class FuntiRunPanel extends StatefulWidget {
  final List<FuntiRunHost> hosts;
  final FuntiRunBoard board;
  final void Function(String hostId, Map<String, dynamic> request) send;
  const FuntiRunPanel(
      {Key? key, required this.hosts, required this.board, required this.send})
      : super(key: key);

  @override
  State<FuntiRunPanel> createState() => _FuntiRunPanelState();
}

class _FuntiRunPanelState extends State<FuntiRunPanel> {
  final _chosen = <String>{};
  final _script = TextEditingController();
  final _open = <String>{};
  String _shell = 'powershell';
  int _timeout = 60;
  bool _asUser = false;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    widget.board.addListener(_changed);
  }

  @override
  void dispose() {
    widget.board.removeListener(_changed);
    _script.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _name(String id) =>
      widget.hosts.firstWhere((h) => h.id == id,
          orElse: () => FuntiRunHost(id, id, '')).name;

  Future<void> _start() async {
    final hosts = widget.hosts
        .where((h) => h.note.isEmpty && _chosen.contains(h.id))
        .toList();
    final script = _script.text;
    if (hosts.isEmpty || script.trim().isEmpty) return;
    final t = FuntiTokens.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('funti-run-confirm')
            .replaceAll('{}', '${hosts.length}')),
        content: SizedBox(
          width: 520,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hosts.map((h) => h.name).join(', '),
                    style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                const SizedBox(height: 10),
                Text('$_shell · ${_timeoutText(_timeout)} · ${translate(_asUser ? 'funti-run-as-user' : 'funti-run-as-system')}',
                    style: TextStyle(fontSize: 12, color: t.muted)),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 240),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: t.surface2, borderRadius: BorderRadius.circular(6)),
                  child: SingleChildScrollView(
                    child: SelectableText(script,
                        style: const TextStyle(
                            fontFamily: 'Consolas', fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 10),
                Text(translate('funti-run-confirm-note'),
                    style: TextStyle(fontSize: 12, color: t.muted)),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(translate('Cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('funti-run-start'))),
        ],
      ),
    );
    if (yes != true) return;
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final run = FuntiRun(
        id, _shell, script, hosts.map((h) => h.id), DateTime.now());
    widget.board.add(run);
    _shown = 0;
    _open.clear();
    for (final h in hosts) {
      widget.send(h.id, funtiRunRequest(id, _shell, script, _timeout, asUser: _asUser));
    }
  }

  /// FuntiDesk updates itself from the release on each chosen computer.
  Future<void> _startUpdate() async {
    final hosts = widget.hosts
        .where((h) => h.note.isEmpty && _chosen.contains(h.id))
        .toList();
    if (hosts.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('funti-run-update-confirm')
            .replaceAll('{}', '${hosts.length}')),
        content: SizedBox(
          width: 480,
          child: Text(
              '${hosts.map((h) => h.name).join(', ')}\n\n${translate('funti-run-update-note')}'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(translate('Cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('funti-run-update'))),
        ],
      ),
    );
    if (yes != true) return;
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    widget.board.add(FuntiRun(id, 'update', translate('funti-run-update'),
        hosts.map((h) => h.id), DateTime.now()));
    _shown = 0;
    _open.clear();
    for (final h in hosts) {
      widget.send(h.id, funtiUpdateRequest(id));
    }
  }

  /// Files to the chosen computers, one after another.
  Future<void> _startSend() async {
    final hosts = widget.hosts
        .where((h) => h.note.isEmpty && _chosen.contains(h.id))
        .toList();
    if (hosts.isEmpty) return;
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = picked?.paths.whereType<String>().toList() ?? const <String>[];
    if (paths.isEmpty || !mounted) return;
    var folder = 'Downloads';
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(translate('funti-send-confirm')
              .replaceAll('{}', '${paths.length}')
              .replaceAll('{n}', '${hosts.length}')),
          content: SizedBox(
            width: 480,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(paths.map((p) => p.split(RegExp(r'[\\/]')).last).join(', '),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(hosts.map((h) => h.name).join(', ')),
                  const SizedBox(height: 10),
                  for (final f in ['Downloads', 'Desktop'])
                    RadioListTile<String>(
                        dense: true,
                        value: f,
                        groupValue: folder,
                        onChanged: (v) => setDialog(() => folder = v ?? folder),
                        title: Text(translate('funti-send-to-$f'))),
                  Text(translate('funti-send-note'),
                      style: const TextStyle(fontSize: 12)),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(translate('Cancel'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(translate('funti-send'))),
          ],
        ),
      ),
    );
    if (yes != true) return;
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final run = FuntiRun(id, 'send', translate('funti-send'),
        hosts.map((h) => h.id), DateTime.now());
    widget.board.add(run);
    _shown = 0;
    _open.clear();
    for (final h in hosts) {
      final answer = await funtiBulkSendOne(h.id, paths, folder);
      widget.board.localAnswer(run, h.id, answer);
    }
  }

  String _timeoutText(int s) => s < 60
      ? translate('funti-run-seconds').replaceAll('{}', '$s')
      : translate('funti-run-minutes').replaceAll('{}', '${s ~/ 60}');

  Widget _hostList(FuntiTokens t) {
    final available = widget.hosts.where((h) => h.note.isEmpty).toList();
    return Container(
      width: 220,
      decoration: BoxDecoration(
          border: Border(right: BorderSide(color: t.rowStroke))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: available.isNotEmpty &&
              available.every((h) => _chosen.contains(h.id)),
          onChanged: (v) => setState(() {
            if (v == true) {
              _chosen.addAll(available.map((h) => h.id));
            } else {
              _chosen.clear();
            }
          }),
          title: Text(translate('funti-run-all'),
              style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
        ),
        Divider(height: 1, color: t.rowStroke),
        Expanded(
          child: ListView(children: [
            for (final h in widget.hosts)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: h.note.isEmpty && _chosen.contains(h.id),
                onChanged: h.note.isNotEmpty
                    ? null
                    : (v) => setState(() =>
                        v == true ? _chosen.add(h.id) : _chosen.remove(h.id)),
                title: Text(h.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: h.note.isEmpty ? t.text : t.muted)),
                subtitle: h.note.isEmpty
                    ? null
                    : Text(translate(h.note),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.muted)),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _results(FuntiTokens t) {
    final runs = widget.board.runs;
    if (runs.isEmpty) {
      return Center(
          child: Text(translate('funti-run-empty'),
              textAlign: TextAlign.center, style: TextStyle(color: t.muted)));
    }
    final run = runs[_shown.clamp(0, runs.length - 1)];
    final error = Theme.of(context).colorScheme.error;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        DropdownButton<int>(
          value: _shown.clamp(0, runs.length - 1),
          underline: const SizedBox.shrink(),
          items: [
            for (var i = 0; i < runs.length; i++)
              DropdownMenuItem(
                  value: i,
                  child: Text(
                      '${runs[i].started.hour.toString().padLeft(2, '0')}:${runs[i].started.minute.toString().padLeft(2, '0')} · ${runs[i].script.trim().split('\n').first}',
                      overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (i) => setState(() {
            _shown = i ?? 0;
            _open.clear();
          }),
        ),
        const SizedBox(width: 12),
        Text(
            translate('funti-run-progress')
                .replaceAll('{done}', '${run.finished}')
                .replaceAll('{all}', '${run.results.length}')
                .replaceAll('{ok}', '${run.succeeded}'),
            style: TextStyle(fontSize: 12, color: t.muted)),
        const Spacer(),
        TextButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: run.report(_name))),
            icon: const Icon(Icons.copy, size: 16),
            label: Text(translate('funti-run-copy'))),
      ]),
      Expanded(
        child: ListView(children: [
          for (final r in run.results.values) ...[
            InkWell(
              onTap: () => setState(() => _open.contains(r.hostId)
                  ? _open.remove(r.hostId)
                  : _open.add(r.hostId)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(children: [
                  !r.done
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline,
                          size: 16, color: r.ok ? t.ok : error),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(_name(r.hostId),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600, color: t.text))),
                  Text(
                      !r.done
                          ? translate('funti-run-running')
                          : r.error.isNotEmpty
                              ? translate(r.error)
                              : r.timedOut
                                  ? translate('funti-run-timeout')
                                  : translate('funti-run-code')
                                      .replaceAll('{}', '${r.code}'),
                      style: TextStyle(fontSize: 12, color: t.muted)),
                  Icon(_open.contains(r.hostId) ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: t.muted),
                ]),
              ),
            ),
            if (_open.contains(r.hostId))
              Container(
                margin: const EdgeInsets.fromLTRB(24, 0, 4, 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: t.surface2, borderRadius: BorderRadius.circular(6)),
                child: SelectableText(
                    r.output.isEmpty
                        ? translate('funti-run-no-output')
                        : r.output.trimRight() +
                            (r.cut ? '\n${translate('funti-run-cut')}' : ''),
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
              ),
            Divider(height: 1, color: t.rowStroke),
          ],
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final count = widget.hosts
        .where((h) => h.note.isEmpty && _chosen.contains(h.id))
        .length;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _hostList(t),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              DropdownButton<String>(
                  value: _shell,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'powershell', child: Text('PowerShell')),
                    DropdownMenuItem(value: 'cmd', child: Text('cmd')),
                  ],
                  onChanged: (v) => setState(() => _shell = v ?? 'powershell')),
              const SizedBox(width: 12),
              Text(translate('funti-run-limit'),
                  style: TextStyle(fontSize: 12, color: t.muted)),
              const SizedBox(width: 6),
              DropdownButton<int>(
                  value: _timeout,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final s in _timeouts)
                      DropdownMenuItem(value: s, child: Text(_timeoutText(s)))
                  ],
                  onChanged: (v) => setState(() => _timeout = v ?? 60)),
              const SizedBox(width: 12),
              PopupMenuButton<int>(
                tooltip: translate('funti-run-presets'),
                onSelected: (i) => setState(() {
                  _shell = _presets[i].$2;
                  _script.text = _presets[i].$3;
                }),
                itemBuilder: (_) => [
                  for (var i = 0; i < _presets.length; i++)
                    PopupMenuItem(value: i, child: Text(translate(_presets[i].$1))),
                ],
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.bolt, size: 16, color: t.muted),
                  const SizedBox(width: 4),
                  Text(translate('funti-run-presets'),
                      style: TextStyle(fontSize: 13, color: t.text)),
                  Icon(Icons.arrow_drop_down, color: t.muted),
                ]),
              ),
              const Spacer(),
              OutlinedButton.icon(
                  onPressed: count == 0 ? null : _startSend,
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: Text(translate('funti-send'))),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                  onPressed: count == 0 ? null : _startUpdate,
                  icon: const Icon(Icons.system_update_alt, size: 18),
                  label: Text(translate('funti-run-update'))),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                  onPressed: count == 0 ? null : _start,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(translate('funti-run-start-n')
                      .replaceAll('{}', '$count'))),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: TextField(
                controller: _script,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                decoration: InputDecoration(
                    hintText: translate('funti-run-hint'),
                    border: const OutlineInputBorder()),
              ),
            ),
            Row(children: [
              Checkbox(
                  value: _asUser,
                  onChanged: (v) => setState(() => _asUser = v ?? false)),
              Text(translate('funti-run-as-user'),
                  style: TextStyle(fontSize: 13, color: t.text)),
              const SizedBox(width: 6),
              Tooltip(
                  message: translate('funti-run-as-user-hint'),
                  child: Icon(Icons.info_outline, size: 16, color: t.muted)),
            ]),
            Text(translate(_asUser ? 'funti-run-note-user' : 'funti-run-note'),
                style: TextStyle(fontSize: 11, color: t.muted)),
            const SizedBox(height: 8),
            Expanded(child: _results(t)),
          ]),
        ),
      ),
    ]);
  }
}
