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

/// What the other computer answered, per session.
class _Answers {
  final status = Rxn<FuntiAdminStatus>();
  final processes = Rxn<List<FuntiAdminProcess>>();
  final killed = Rxn<Map<String, dynamic>>();
  final services = Rxn<List<FuntiAdminService>>();
  final serviceDone = Rxn<Map<String, dynamic>>();
}

final _answers = <String, _Answers>{};

_Answers _of(FFI ffi) =>
    _answers.putIfAbsent(ffi.sessionId.toString(), () => _Answers());

void _ask(FFI ffi, Map<String, dynamic> request) => bind.sessionFuntiAdmin(
    sessionId: ffi.sessionId, request: jsonEncode(request));

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
      _ask(ffi, {'op': 'services'});
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

/// "Processes…" in the session menu: the list refreshes every three
/// seconds; "End" asks once more in the same row.
void showFuntiAdminProcesses(FFI ffi) {
  final a = _of(ffi);
  a.processes.value = null;
  a.killed.value = null;
  _ask(ffi, {'op': 'processes'});
  final timer = Timer.periodic(
      const Duration(seconds: 3), (_) => _ask(ffi, {'op': 'processes'}));
  final search = TextEditingController();
  var byMemory = false;
  int? confirm;
  ffi.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    void done() {
      timer.cancel();
      close();
    }

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
                  : confirm == p.pid
                      ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(
                              onPressed: () {
                                _ask(ffi, {'op': 'kill', 'pid': p.pid});
                                setState(() => confirm = null);
                              },
                              child: Text(translate('funti-admin-end-yes'),
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                          TextButton(
                              onPressed: () => setState(() => confirm = null),
                              child: Text(translate('Cancel'))),
                        ])
                      : Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                              onPressed: () =>
                                  setState(() => confirm = p.pid),
                              child: Text(translate('funti-admin-end')))),
            ),
          ]),
        );

    return CustomAlertDialog(
      title: Text(translate('funti-admin-processes')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 720),
      content: SizedBox(
        width: 720,
        height: 460,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 18),
                        hintText: translate('funti-admin-search')))),
            const SizedBox(width: 12),
            TextButton(
                onPressed: () => setState(() => byMemory = !byMemory),
                child: Text(translate(byMemory
                    ? 'funti-admin-sort-memory'
                    : 'funti-admin-sort-cpu'))),
          ]),
          const SizedBox(height: 6),
          Obx(() {
            final k = a.killed.value;
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
            final list = a.processes.value;
            if (list == null) {
              return Center(
                  child: Text(translate('funti-admin-waiting'),
                      style: TextStyle(color: t.muted)));
            }
            final shown = funtiAdminSorted(list, search.text, byMemory);
            return ListView.builder(
                itemCount: shown.length,
                itemExtent: 34,
                itemBuilder: (context, i) => row(shown[i]));
          })),
        ]),
      ),
      actions: [dialogButton('Close', onPressed: done)],
      onCancel: done,
    );
  });
}

/// "Services…" in the session menu (Windows): the list with the state and
/// start type; start, stop and restart ask once more in the same row.
/// Services Windows cannot do without, and FuntiDesk's own, are only shown.
void showFuntiAdminServices(FFI ffi) {
  final a = _of(ffi);
  a.services.value = null;
  a.serviceDone.value = null;
  _ask(ffi, {'op': 'services'});
  final search = TextEditingController();
  String? confirm; // "<name>/<action>"
  final busy = <String>{};
  ffi.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);

    void act(FuntiAdminService s, String action) {
      _ask(ffi, {'op': 'service', 'name': s.name, 'action': action});
      setState(() {
        confirm = null;
        busy.add(s.name);
      });
    }

    Widget button(FuntiAdminService s, String action) {
      final key = '${s.name}/$action';
      if (confirm == key) {
        return TextButton(
            onPressed: () => act(s, action),
            child: Text(translate('funti-admin-service-$action-yes'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)));
      }
      return TextButton(
          onPressed: () => setState(() => confirm = key),
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
                        fontSize: 12,
                        color: s.running ? t.text : t.muted))),
            SizedBox(
              width: 230,
              child: s.protected
                  ? const SizedBox()
                  : busy.contains(s.name)
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

    return CustomAlertDialog(
      title: Text(translate('funti-admin-services')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 760),
      content: SizedBox(
        width: 760,
        height: 480,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: translate('funti-admin-search'))),
          const SizedBox(height: 6),
          Obx(() {
            final done = a.serviceDone.value;
            if (done == null) return const Offstage();
            // The answer ends the wait for that service.
            final name = done['name'];
            if (name is String) busy.remove(name);
            final error = done['error'];
            if (error is String) busy.clear();
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
            final list = a.services.value;
            if (list == null) {
              return Center(
                  child: Text(translate('funti-admin-waiting'),
                      style: TextStyle(color: t.muted)));
            }
            final shown = funtiAdminServicesShown(list, search.text);
            return ListView.builder(
                itemCount: shown.length,
                itemExtent: 44,
                itemBuilder: (context, i) => row(shown[i]));
          })),
        ]),
      ),
      actions: [dialogButton('Close', onPressed: close)],
      onCancel: close,
    );
  });
}
