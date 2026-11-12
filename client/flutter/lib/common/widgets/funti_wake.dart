// FUNTIDESK (ADR-021): "Wake a device" in the session menu. The other
// computer (one that is on, say a mini PC at home) sends the Wake-on-LAN
// packet into its own local network: to a computer with FuntiDesk it has
// seen there, or to any device by its network card address.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/funti_theme.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

/// Whoever may control the other computer may ask it to wake a device.
bool funtiPeerCanWake(FFI ffi) =>
    ffi.connType == ConnType.defaultConn &&
    !ffi.ffiModel.viewOnly &&
    ffi.ffiModel.keyboard &&
    (ffi.ffiModel.pi.platform == kPeerPlatformWindows ||
        ffi.ffiModel.pi.platform == kPeerPlatformLinux ||
        ffi.ffiModel.pi.platform == kPeerPlatformMacOS);

final _waiting = <String, Completer<Map<String, dynamic>?>>{};

/// The "funti_wake" session event: the answer of the other computer.
void funtiWakeOnEvent(FFI ffi, Map<String, dynamic> evt) {
  Map<String, dynamic>? answer;
  try {
    answer = jsonDecode(evt['result'] as String) as Map<String, dynamic>;
  } catch (e) {
    debugPrint('Wake answer: $e');
  }
  _waiting.remove(ffi.sessionId.toString())?.complete(answer);
}

/// Null: no answer (an older FuntiDesk there, or no right to control).
Future<Map<String, dynamic>?> _ask(FFI ffi, Map<String, dynamic>? request) {
  final key = ffi.sessionId.toString();
  _waiting.remove(key)?.complete(null);
  final answer = Completer<Map<String, dynamic>?>();
  _waiting[key] = answer;
  bind.sessionFuntiWake(
      sessionId: ffi.sessionId,
      request: request == null ? '' : jsonEncode(request));
  return answer.future.timeout(const Duration(seconds: 8), onTimeout: () {
    _waiting.remove(key);
    return null;
  });
}

void showFuntiWakeDialog(FFI ffi) {
  Future<Map<String, dynamic>?> answer = _ask(ffi, null);
  final name = TextEditingController();
  final mac = TextEditingController();
  var status = '';
  ffi.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    void send(Map<String, dynamic> request, String title) {
      setState(() {
        status = '';
        answer = _ask(ffi, request).then((res) {
          final error = res?['error'];
          setState(() => status = res == null
              ? translate('funti-wake-no-answer')
              : error is String
                  ? translate(error)
                  : res['sent'] == true
                      ? translate('funti-wake-sent').replaceAll('{}', title)
                      : '');
          return res;
        });
      });
    }

    Widget device(Map<String, dynamic> d) {
      final id = d['id'] is String ? d['id'] as String : '';
      final address = d['mac'] is String ? d['mac'] as String : '';
      final label = d['name'] is String && (d['name'] as String).isNotEmpty
          ? d['name'] as String
          : address;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(d['saved'] == true ? Icons.bookmark_outline : Icons.computer,
              size: 20, color: t.text),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: t.text)),
                  Text(id.isEmpty ? address : '${formatID(id)} · $address',
                      style: TextStyle(fontSize: 12, color: t.muted)),
                ]),
          ),
          if (d['saved'] == true)
            IconButton(
                tooltip: translate('funti-wake-forget'),
                icon: Icon(Icons.close, size: 18, color: t.muted),
                onPressed: () => send({'forget': address}, label)),
          OutlinedButton(
              onPressed: () => send({'mac': address}, label),
              child: Text(translate('funti-wake-on'))),
        ]),
      );
    }

    return CustomAlertDialog(
      title: Text(translate('funti-wake')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 520),
      content: SizedBox(
        width: 520,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('funti-wake-note'),
                  style: TextStyle(fontSize: 12, color: t.muted)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: FutureBuilder<Map<String, dynamic>?>(
                  future: answer,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()));
                    }
                    final res = snapshot.data;
                    final list = res?['devices'];
                    if (res == null) {
                      return Text(translate('funti-wake-no-answer'),
                          style: TextStyle(color: t.muted));
                    }
                    if (list is! List || list.isEmpty) {
                      return Text(translate('funti-wake-empty'),
                          style: TextStyle(color: t.muted));
                    }
                    return ListView(shrinkWrap: true, children: [
                      for (final d in list)
                        if (d is Map<String, dynamic>) device(d)
                    ]);
                  },
                ),
              ),
              Divider(height: 20, color: t.rowStroke),
              Text(translate('funti-wake-other'),
                  style: TextStyle(fontSize: 13, color: t.text)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: name,
                        maxLength: 40,
                        decoration: InputDecoration(
                            counterText: '',
                            isDense: true,
                            hintText: translate('funti-wake-name')))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: mac,
                        maxLength: 17,
                        decoration: const InputDecoration(
                            counterText: '',
                            isDense: true,
                            hintText: 'AA:BB:CC:DD:EE:FF'))),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: () {
                      final address = mac.text.trim();
                      if (address.isEmpty) return;
                      send({'mac': address, 'name': name.text.trim()},
                          name.text.trim().isEmpty ? address : name.text.trim());
                    },
                    child: Text(translate('funti-wake-on'))),
              ]),
              if (status.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(status,
                        style: TextStyle(fontSize: 13, color: t.text))),
            ]),
      ),
      actions: [dialogButton('Close', onPressed: close)],
      onCancel: close,
    );
  });
}
