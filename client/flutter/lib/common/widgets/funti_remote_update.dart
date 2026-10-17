// FUNTIDESK (ADR-007, stage 3): update FuntiDesk on the other computer from
// a session. The other side tells its build in the peer info
// (`funti_build`, `funti_updatable`); this side compares it with the latest
// release and, on "Update", asks it to install the release itself. It
// downloads and checks the release the same way as its own "Update" button.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

Future<Map<String, dynamic>>? _latest;

/// One release check per window; a failed one is tried again next time.
Future<Map<String, dynamic>> _latestRelease() {
  _latest ??= bind.mainFuntiUpdateCheck().then((s) {
    final res = jsonDecode(s) as Map<String, dynamic>;
    if (res['error'] != null) _latest = null;
    return res;
  });
  return _latest!;
}

/// Whoever may control the other computer may update it.
bool funtiPeerUpdatable(FFI ffi) =>
    ffi.connType == ConnType.defaultConn &&
    !ffi.ffiModel.viewOnly &&
    ffi.ffiModel.keyboard &&
    ffi.ffiModel.pi.platformAdditions['funti_updatable'] == true;

int _peerBuild(FFI ffi) {
  final build = ffi.ffiModel.pi.platformAdditions['funti_build'];
  return build is int ? build : 0;
}

/// The latest release if it is newer than the other computer's build.
Future<Map<String, dynamic>?> _newerRelease(FFI ffi) async {
  final res = await _latestRelease();
  final build = res['build'];
  if (res['error'] != null || build is! int) return null;
  return build > _peerBuild(ffi) ? res : null;
}

/// After connecting: a short hint if the other computer is out of date.
Future<void> funtiNotifyOldPeer(FFI ffi) async {
  if (!funtiPeerUpdatable(ffi)) return;
  try {
    if (await _newerRelease(ffi) == null) return;
  } catch (_) {
    return;
  }
  showToast(translate('funti-update-remote-old'),
      timeout: const Duration(seconds: 6));
}

/// "Update FuntiDesk on that computer" in the session menu.
Future<void> funtiUpdatePeer(FFI ffi) async {
  Map<String, dynamic>? latest;
  String error = '';
  try {
    latest = await _newerRelease(ffi);
    if (latest == null && _latest == null) error = 'check';
  } catch (_) {
    error = 'check';
  }
  final text = error.isNotEmpty
      ? translate('funti-update-remote-check-failed')
      : latest == null
          ? translate('funti-update-remote-latest')
          : translate('funti-update-remote-confirm')
              .replaceFirst('{}', 'ft.${_peerBuild(ffi)}')
              .replaceFirst('{}', latest['version'].toString());
  final res = await ffi.dialogManager.show<bool>(
      (setState, close, context) => CustomAlertDialog(
            title: Text(translate('funti-update-remote-title')),
            content: Text(text),
            actions: [
              if (latest != null)
                dialogButton('Cancel', onPressed: close, isOutline: true),
              dialogButton(latest != null ? 'funti-update-now' : 'OK',
                  onPressed: () => close(latest != null)),
            ],
            onCancel: close,
            onSubmit: () => close(latest != null),
          ));
  if (res == true) bind.sessionFuntiUpdatePeer(sessionId: ffi.sessionId);
}
