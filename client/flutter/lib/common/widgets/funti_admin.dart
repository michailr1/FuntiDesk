// FUNTIDESK (ADR-023): the administration layer in a session. A thin bar
// shows the other computer's processor, memory and system disk; whoever may
// control that computer also gets its processes and can end one.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../consts.dart';
import '../../funti/admin_rules.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

const _kBarOption = 'funti-admin-bar';

/// The owner's choice for all sessions: shown unless hidden.
final funtiAdminBarShown =
    (bind.mainGetLocalOption(key: _kBarOption) != 'N').obs;

void funtiAdminToggleBar() {
  funtiAdminBarShown.value = !funtiAdminBarShown.value;
  bind.mainSetLocalOption(
      key: _kBarOption, value: funtiAdminBarShown.value ? '' : 'N');
}

bool _desktopPeer(FFI ffi) =>
    ffi.ffiModel.pi.platform == kPeerPlatformWindows ||
    ffi.ffiModel.pi.platform == kPeerPlatformLinux ||
    ffi.ffiModel.pi.platform == kPeerPlatformMacOS;

/// The bar is for every screen session with a desktop computer.
bool funtiPeerHasAdminBar(FFI ffi) =>
    ffi.connType == ConnType.defaultConn && _desktopPeer(ffi);

/// Windows services are only on Windows.
bool funtiPeerHasServices(FFI ffi) =>
    funtiPeerCanAdmin(ffi) &&
    ffi.ffiModel.pi.platform == kPeerPlatformWindows;

/// Whoever may control the other computer sees its processes.
bool funtiPeerCanAdmin(FFI ffi) =>
    funtiPeerHasAdminBar(ffi) &&
    !ffi.ffiModel.viewOnly &&
    ffi.ffiModel.keyboard;

/// Where administration requests go: a session (ADR-023) or a service
/// connection of the workplace (ADR-024). Answers are kept per [key].
class FuntiAdminLink {
  final String key;
  final void Function(String request) _send;
  FuntiAdminLink(this.key, this._send);

  factory FuntiAdminLink.session(FFI ffi) => FuntiAdminLink(
      ffi.sessionId.toString(),
      (r) => bind.sessionFuntiAdmin(sessionId: ffi.sessionId, request: r));

  factory FuntiAdminLink.service(String id) => FuntiAdminLink(
      'svc:$id', (r) => bind.mainFuntiServiceRequest(id: id, request: r));

  void ask(Map<String, dynamic> request) => _send(jsonEncode(request));
}

/// What the other computer answered, per session or host.
class _Answers {
  FuntiAdminLink? link;
  final status = Rxn<FuntiAdminStatus>();
  final processes = Rxn<List<FuntiAdminProcess>>();
  final killed = Rxn<Map<String, dynamic>>();
  final services = Rxn<List<FuntiAdminService>>();
  final serviceDone = Rxn<Map<String, dynamic>>();
  final autostart = Rxn<List<FuntiAdminAutostart>>();
  final autostartDone = Rxn<Map<String, dynamic>>();
  final info = Rxn<Map<String, dynamic>>();
  final journal = Rxn<List<dynamic>>();
  final eventlog = Rxn<Map<String, dynamic>>();
  final programs = Rxn<List<Map<String, dynamic>>>();
  final uninstalled = Rxn<Map<String, dynamic>>();
}

final _answers = <String, _Answers>{};

_Answers _ofKey(String key) => _answers.putIfAbsent(key, () => _Answers());

_Answers _of(FFI ffi) => _ofKey(ffi.sessionId.toString());

void _ask(FFI ffi, Map<String, dynamic> request) => bind.sessionFuntiAdmin(
    sessionId: ffi.sessionId, request: jsonEncode(request));

/// Forget what a host or session answered (it is gone).
void funtiAdminForget(String key) => _answers.remove(key);

Rxn<FuntiAdminStatus> funtiAdminStatusOf(String key) => _ofKey(key).status;
Rxn<Map<String, dynamic>> funtiAdminInfoOf(String key) => _ofKey(key).info;
Rxn<List<dynamic>> funtiAdminJournalOf(String key) => _ofKey(key).journal;
Rxn<Map<String, dynamic>> funtiAdminEventLogOf(String key) =>
    _ofKey(key).eventlog;
Rxn<List<Map<String, dynamic>>> funtiAdminProgramsOf(String key) =>
    _ofKey(key).programs;
Rxn<Map<String, dynamic>> funtiAdminUninstalledOf(String key) =>
    _ofKey(key).uninstalled;

/// The "funti_admin" session event.
void funtiAdminOnEvent(FFI ffi, Map<String, dynamic> evt) {
  dynamic answer;
  try {
    answer = jsonDecode(evt['result'] as String);
  } catch (e) {
    debugPrint('Admin answer: $e');
    return;
  }
  if (answer is! Map<String, dynamic>) return;
  final a = _of(ffi);
  a.link ??= FuntiAdminLink.session(ffi);
  funtiAdminOnAnswer(ffi.sessionId.toString(), answer);
}

/// An answer of the other computer, for session or host [key].
void funtiAdminOnAnswer(String key, Map<String, dynamic> answer) {
  final a = _ofKey(key);
  switch (answer['op']) {
    case 'status':
      a.status.value = FuntiAdminStatus.parse(answer);
      break;
    case 'processes':
      a.processes.value = funtiAdminProcesses(answer);
      break;
    case 'kill':
      a.killed.value = answer;
      break;
    case 'services':
      a.services.value = funtiAdminServices(answer);
      break;
    case 'service':
      a.serviceDone.value = answer;
      a.link?.ask({'op': 'services'});
      break;
    case 'autostart':
      if (answer['error'] != null) {
        a.autostartDone.value = answer;
        a.autostart.value = const [];
      } else {
        a.autostart.value = funtiAdminAutostart(answer);
      }
      break;
    case 'autostart_set':
      a.autostartDone.value = answer;
      a.link?.ask({'op': 'autostart'});
      break;
    case 'info':
      if (answer['error'] == null) a.info.value = answer;
      break;
    case 'programs':
      final list = answer['programs'];
      a.programs.value = list is List
          ? [
              for (final p in list)
                if (p is Map) Map<String, dynamic>.from(p)
            ]
          : const [];
      if (answer['error'] != null) a.uninstalled.value = answer;
      break;
    case 'uninstall':
      a.uninstalled.value = answer;
      a.link?.ask({'op': 'programs'});
      break;
    case 'journal':
      final events = answer['events'];
      if (events is List) a.journal.value = events;
      break;
    case 'eventlog':
      a.eventlog.value = answer;
      break;
  }
}

/// The state bar: asks every two seconds while the session is open. It
/// stays hidden until the other computer answers (an older FuntiDesk there
/// never does) and lets the mouse through to the remote screen.
class FuntiAdminBar extends StatefulWidget {
  final FFI ffi;
  const FuntiAdminBar({Key? key, required this.ffi}) : super(key: key);

  @override
  State<FuntiAdminBar> createState() => _FuntiAdminBarState();
}

class _FuntiAdminBarState extends State<FuntiAdminBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void _tick() {
    final ffi = widget.ffi;
    if (!funtiAdminBarShown.value ||
        ffi.ffiModel.pi.isSet.isFalse ||
        !funtiPeerHasAdminBar(ffi)) {
      return;
    }
    _ask(ffi, {'op': 'status'});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _answers.remove(widget.ffi.sessionId.toString());
    super.dispose();
  }

  Widget _value(String label, int percent) => Text.rich(TextSpan(children: [
        TextSpan(
            text: '$label ', style: const TextStyle(color: Colors.white70)),
        TextSpan(
            text: '$percent%',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: percent > funtiAdminHot
                    ? const Color(0xFFFF8A80)
                    : Colors.white)),
      ]));

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final s = _of(widget.ffi).status.value;
      if (!funtiAdminBarShown.value || s == null) return const Offstage();
      return IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(10)),
          child: DefaultTextStyle(
            style: const TextStyle(fontSize: 12, color: Colors.white),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _value(translate('funti-admin-cpu'), s.cpu),
              const SizedBox(width: 12),
              _value(translate('funti-admin-memory'), s.memory),
              if (s.diskName.isNotEmpty) ...[
                const SizedBox(width: 12),
                _value(
                    '${translate('funti-admin-disk')} ${s.diskName}', s.disk),
              ],
            ]),
          ),
        ),
      );
    });
  }
}

Widget _waiting(FuntiTokens t) => Center(
    child: Text(translate('funti-admin-waiting'),
        style: TextStyle(color: t.muted)));

Widget _searchField(TextEditingController c, VoidCallback onChanged) =>
    TextField(
        controller: c,
        onChanged: (_) => onChanged(),
        decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: translate('funti-admin-search')));

/// Processes of the other computer; refreshes every three seconds. "End"
/// asks once more in the same row.
class FuntiProcessesPanel extends StatefulWidget {
  final FuntiAdminLink link;
  const FuntiProcessesPanel({Key? key, required this.link}) : super(key: key);

  @override
  State<FuntiProcessesPanel> createState() => _FuntiProcessesPanelState();
}

class _FuntiProcessesPanelState extends State<FuntiProcessesPanel> {
  final _search = TextEditingController();
  bool _byMemory = false;
  int? _confirm;
  Timer? _timer;
  late _Answers _a;

  @override
  void initState() {
    super.initState();
    _a = _ofKey(widget.link.key)..link = widget.link;
    _a.processes.value = null;
    _a.killed.value = null;
    widget.link.ask({'op': 'processes'});
    _timer = Timer.periodic(const Duration(seconds: 3),
        (_) => widget.link.ask({'op': 'processes'}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    Widget row(FuntiAdminProcess p) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
                flex: 5,
                child: Text(p.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: t.text))),
            SizedBox(
                width: 56,
                child: Text('${p.cpu.toStringAsFixed(1)}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 13, color: t.text))),
            SizedBox(
                width: 84,
                child: Text(readableFileSize(p.memory.toDouble()),
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 13, color: t.text))),
            const SizedBox(width: 10),
            Expanded(
                flex: 3,
                child: Text(p.user,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.muted))),
            SizedBox(
              width: 150,
              child: p.protected
                  ? const SizedBox(height: 30)
                  : _confirm == p.pid
                      ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(
                              onPressed: () {
                                widget.link.ask({'op': 'kill', 'pid': p.pid});
                                setState(() => _confirm = null);
                              },
                              child: Text(translate('funti-admin-end-yes'),
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                          TextButton(
                              onPressed: () => setState(() => _confirm = null),
                              child: Text(translate('Cancel'))),
                        ])
                      : Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                              onPressed: () =>
                                  setState(() => _confirm = p.pid),
                              child: Text(translate('funti-admin-end')))),
            ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _searchField(_search, () => setState(() {}))),
        const SizedBox(width: 12),
        TextButton(
            onPressed: () => setState(() => _byMemory = !_byMemory),
            child: Text(translate(_byMemory
                ? 'funti-admin-sort-memory'
                : 'funti-admin-sort-cpu'))),
      ]),
      const SizedBox(height: 6),
      Obx(() {
        final k = _a.killed.value;
        if (k == null) return const Offstage();
        final error = k['error'];
        return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
                error is String
                    ? translate(error)
                    : translate('funti-admin-ended')
                        .replaceAll('{}', '${k['name']}'),
                style: TextStyle(fontSize: 13, color: t.text)));
      }),
      Expanded(child: Obx(() {
        final list = _a.processes.value;
        if (list == null) return _waiting(t);
        final shown = funtiAdminSorted(list, _search.text, _byMemory);
        return ListView.builder(
            itemCount: shown.length,
            itemExtent: 34,
            itemBuilder: (context, i) => row(shown[i]));
      })),
    ]);
  }
}

/// Windows services: the list with the state and start type; start, stop
/// and restart ask once more in the same row. Services Windows cannot do
/// without, and FuntiDesk's own, are only shown.
class FuntiServicesPanel extends StatefulWidget {
  final FuntiAdminLink link;
  const FuntiServicesPanel({Key? key, required this.link}) : super(key: key);

  @override
  State<FuntiServicesPanel> createState() => _FuntiServicesPanelState();
}

class _FuntiServicesPanelState extends State<FuntiServicesPanel> {
  final _search = TextEditingController();
  String? _confirm; // "<name>/<action>"
  final _busy = <String>{};
  late _Answers _a;

  @override
  void initState() {
    super.initState();
    _a = _ofKey(widget.link.key)..link = widget.link;
    _a.services.value = null;
    _a.serviceDone.value = null;
    widget.link.ask({'op': 'services'});
  }

  void _act(FuntiAdminService s, String action) {
    widget.link.ask({'op': 'service', 'name': s.name, 'action': action});
    setState(() {
      _confirm = null;
      _busy.add(s.name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    Widget button(FuntiAdminService s, String action) {
      final key = '${s.name}/$action';
      if (_confirm == key) {
        return TextButton(
            onPressed: () => _act(s, action),
            child: Text(translate('funti-admin-service-$action-yes'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)));
      }
      return TextButton(
          onPressed: () => setState(() => _confirm = key),
          child: Text(translate('funti-admin-service-$action')));
    }

    Widget row(FuntiAdminService s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(s.display,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: t.text)),
                    Text(
                        '${s.name} · ${translate('funti-admin-start-${s.start}')}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.muted)),
                  ]),
            ),
            SizedBox(
                width: 110,
                child: Text(translate('funti-admin-state-${s.state}'),
                    style: TextStyle(
                        fontSize: 12, color: s.running ? t.text : t.muted))),
            SizedBox(
              width: 230,
              child: s.protected
                  ? const SizedBox()
                  : _busy.contains(s.name)
                      ? Text(translate('funti-admin-service-busy'),
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 12, color: t.muted))
                      : Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          if (s.stopped) button(s, 'start'),
                          if (s.running) button(s, 'restart'),
                          if (s.running) button(s, 'stop'),
                        ]),
            ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _searchField(_search, () => setState(() {})),
      const SizedBox(height: 6),
      Obx(() {
        final done = _a.serviceDone.value;
        if (done == null) return const Offstage();
        // The answer ends the wait for that service.
        final name = done['name'];
        if (name is String) _busy.remove(name);
        final error = done['error'];
        if (error is String) _busy.clear();
        return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
                error is String
                    ? translate(error)
                    : translate('funti-admin-service-done-${done['action']}')
                        .replaceAll('{}', '$name'),
                style: TextStyle(fontSize: 13, color: t.text)));
      }),
      Expanded(child: Obx(() {
        final list = _a.services.value;
        if (list == null) return _waiting(t);
        final shown = funtiAdminServicesShown(list, _search.text);
        return ListView.builder(
            itemCount: shown.length,
            itemExtent: 44,
            itemBuilder: (context, i) => row(shown[i]));
      })),
    ]);
  }
}

/// Programs that start with Windows, for every user and for the signed-in
/// one. "Turn off" works as in Task Manager — nothing is deleted.
class FuntiAutostartPanel extends StatefulWidget {
  final FuntiAdminLink link;
  const FuntiAutostartPanel({Key? key, required this.link}) : super(key: key);

  @override
  State<FuntiAutostartPanel> createState() => _FuntiAutostartPanelState();
}

class _FuntiAutostartPanelState extends State<FuntiAutostartPanel> {
  late _Answers _a;

  @override
  void initState() {
    super.initState();
    _a = _ofKey(widget.link.key)..link = widget.link;
    _a.autostart.value = null;
    _a.autostartDone.value = null;
    widget.link.ask({'op': 'autostart'});
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    Widget row(FuntiAdminAutostart e) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(e.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            color: e.enabled ? t.text : t.muted)),
                    Text(e.command,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.muted)),
                  ]),
            ),
            SizedBox(
                width: 150,
                child: Text(
                    translate(e.everyone
                        ? 'funti-admin-autostart-everyone'
                        : 'funti-admin-autostart-this-user'),
                    style: TextStyle(fontSize: 12, color: t.muted))),
            SizedBox(
              width: 120,
              child: e.protected
                  ? const SizedBox()
                  : Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: () => widget.link.ask({
                                'op': 'autostart_set',
                                'source': e.source,
                                'name': e.name,
                                'enabled': !e.enabled,
                              }),
                          child: Text(translate(e.enabled
                              ? 'funti-admin-autostart-off'
                              : 'funti-admin-autostart-on')))),
            ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(translate('funti-admin-autostart-note'),
          style: TextStyle(fontSize: 12, color: t.muted)),
      const SizedBox(height: 6),
      Obx(() {
        final done = _a.autostartDone.value;
        if (done == null) return const Offstage();
        final error = done['error'];
        return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
                error is String
                    ? translate(error)
                    : translate(done['enabled'] == true
                            ? 'funti-admin-autostart-done-on'
                            : 'funti-admin-autostart-done-off')
                        .replaceAll('{}', '${done['name']}'),
                style: TextStyle(fontSize: 13, color: t.text)));
      }),
      Expanded(child: Obx(() {
        final list = _a.autostart.value;
        if (list == null) return _waiting(t);
        if (list.isEmpty) {
          return Center(
              child: Text(translate('funti-admin-autostart-empty'),
                  style: TextStyle(color: t.muted)));
        }
        return ListView.builder(
            itemCount: list.length,
            itemExtent: 44,
            itemBuilder: (context, i) => row(list[i]));
      })),
    ]);
  }
}

void _showPanel(FFI ffi, String title, double width, double height, Widget panel) {
  ffi.dialogManager.show((setState, close, context) => CustomAlertDialog(
        title: Text(translate(title)),
        contentBoxConstraints: BoxConstraints(maxWidth: width),
        content: SizedBox(width: width, height: height, child: panel),
        actions: [dialogButton('Close', onPressed: close)],
        onCancel: close,
      ));
}

/// "Processes…" in the session menu.
void showFuntiAdminProcesses(FFI ffi) => _showPanel(ffi, 'funti-admin-processes',
    720, 460, FuntiProcessesPanel(link: FuntiAdminLink.session(ffi)));

/// "Services…" in the session menu (Windows).
void showFuntiAdminServices(FFI ffi) => _showPanel(ffi, 'funti-admin-services',
    760, 480, FuntiServicesPanel(link: FuntiAdminLink.session(ffi)));

/// "Autostart…" in the session menu (Windows).
void showFuntiAdminAutostart(FFI ffi) => _showPanel(ffi, 'funti-admin-autostart',
    720, 420, FuntiAutostartPanel(link: FuntiAdminLink.session(ffi)));

/// FUNTIDESK (ADR-024, stage 5): installed programs, removal by Windows
/// Installer or the program's quiet uninstaller, after a confirmation.
class FuntiProgramsPanel extends StatefulWidget {
  final FuntiAdminLink link;
  const FuntiProgramsPanel({Key? key, required this.link}) : super(key: key);

  @override
  State<FuntiProgramsPanel> createState() => _FuntiProgramsPanelState();
}

class _FuntiProgramsPanelState extends State<FuntiProgramsPanel> {
  final _search = TextEditingController();
  final _removing = <String>{};
  late _Answers _a;

  @override
  void initState() {
    super.initState();
    _a = _ofKey(widget.link.key)..link = widget.link;
    _a.programs.value = null;
    _a.uninstalled.value = null;
    widget.link.ask({'op': 'programs'});
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _date(String d) => d.length == 8
      ? '${d.substring(6, 8)}.${d.substring(4, 6)}.${d.substring(0, 4)}'
      : d;

  Future<void> _remove(Map<String, dynamic> p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('funti-programs-remove-title')
            .replaceAll('{}', '${p['name']}')),
        content: Text(translate('funti-programs-remove-note')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(translate('Cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('funti-programs-remove'))),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _removing.add('${p['id']}'));
    _a.uninstalled.value = null;
    widget.link.ask({'op': 'uninstall', 'id': p['id']});
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final error = Theme.of(context).colorScheme.error;
    return Obx(() {
      final list = _a.programs.value;
      final done = _a.uninstalled.value;
      if (done != null) _removing.remove('${done['id']}');
      final filter = _search.text.trim().toLowerCase();
      final shown = (list ?? const <Map<String, dynamic>>[])
          .where((p) =>
              filter.isEmpty ||
              '${p['name']} ${p['publisher']}'.toLowerCase().contains(filter))
          .toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: translate('funti-programs-search')),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
              tooltip: translate('Refresh'),
              onPressed: () => widget.link.ask({'op': 'programs'}),
              icon: const Icon(Icons.refresh, size: 18)),
          const Spacer(),
          if (list != null)
            Text(translate('funti-programs-count').replaceAll('{}', '${list.length}'),
                style: TextStyle(fontSize: 12, color: t.muted)),
        ]),
        if (done != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                done['error'] is String
                    ? translate('${done['error']}')
                    : translate('funti-programs-removed')
                        .replaceAll('{}', '${done['name']}'),
                style: TextStyle(
                    fontSize: 13,
                    color: done['error'] is String ? error : t.ok)),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: list == null
              ? Center(
                  child: Text(translate('funti-admin-waiting'),
                      style: TextStyle(color: t.muted)))
              : ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: t.rowStroke),
                  itemBuilder: (context, i) {
                    final p = shown[i];
                    final id = '${p['id']}';
                    final size = (p['size'] is num) ? (p['size'] as num).toDouble() : 0.0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${p['name']}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 13, color: t.text)),
                                Text(
                                    [
                                      '${p['version'] ?? ''}',
                                      '${p['publisher'] ?? ''}',
                                      _date('${p['date'] ?? ''}'),
                                      if (size > 0) readableFileSize(size),
                                    ].where((x) => x.isNotEmpty).join(' · '),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11, color: t.muted)),
                              ]),
                        ),
                        if (_removing.contains(id))
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                        else if (p['removable'] == true)
                          TextButton(
                              onPressed: () => _remove(p),
                              child: Text(translate('funti-programs-remove')))
                        else
                          Tooltip(
                            message: translate(p['protected'] == true
                                ? 'funti-admin-protected'
                                : 'funti-programs-manual'),
                            child: Icon(Icons.info_outline, size: 16, color: t.muted),
                          ),
                      ]),
                    );
                  }),
        ),
      ]);
    });
  }
}
