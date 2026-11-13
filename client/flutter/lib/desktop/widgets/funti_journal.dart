// FUNTIDESK (ADR-020): the journal of incoming connections kept by the
// service on this computer — who got in, for how long, which files moved,
// which attempts were refused. Shown from Settings → Computer access.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/funti_theme.dart';
import '../../funti/journal_rules.dart';
import '../../models/platform_model.dart';

Future<List<FuntiJournalRow>?> _load({bool clear = false}) async {
  try {
    final json = await bind.mainFuntiJournal(clear: clear);
    if (json.isEmpty) return null;
    return funtiJournalRows(jsonDecode(json) as List<dynamic>);
  } catch (e) {
    debugPrint('Connection journal: $e');
    return null;
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String _when(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${_two(d.day)}.${_two(d.month)}.${d.year} ${_two(d.hour)}:${_two(d.minute)}';
}

String _who(FuntiJournalRow r) {
  final id = r.peer.isEmpty ? '' : formatID(r.peer);
  if (r.name.isEmpty) return id.isEmpty ? r.ip : id;
  return id.isEmpty ? r.name : '${r.name} ($id)';
}

String _refusedReason(int alarm) {
  switch (alarm) {
    case 0:
    case 10:
      return translate('funti-journal-alarm-list');
    case 1:
    case 2:
    case 6:
    case 7:
    case 8:
      return translate('funti-journal-alarm-attempts');
    default:
      return translate('funti-journal-alarm-other');
  }
}

const _typeIcons = [
  Icons.desktop_windows_outlined,
  Icons.folder_outlined,
  Icons.swap_horiz,
  Icons.videocam_outlined,
  Icons.terminal,
  // ADR-024: a service connection of the administrator's workplace.
  Icons.monitor_heart_outlined,
];

Widget _row(BuildContext context, FuntiJournalRow r) {
  final t = FuntiTokens.of(context);
  final error = Theme.of(context).colorScheme.error;
  final lines = <String>[];
  var icon = Icons.info_outline;
  var color = t.text;
  var title = '';
  switch (r.kind) {
    case 'session':
      final type = r.type >= 0 && r.type < _typeIcons.length ? r.type : 0;
      icon = _typeIcons[type];
      title = _who(r);
      final length = r.seconds == null
          ? translate('funti-journal-open-end')
          : funtiJournalDuration(r.seconds!, translate('funti-journal-sec'),
              translate('funti-journal-min'), translate('funti-journal-hour'));
      lines.add([
        _when(r.time),
        translate('funti-journal-type-$type'),
        length,
        if (r.ip.isNotEmpty) r.ip,
      ].join(' · '));
      break;
    case 'files':
      icon = Icons.folder_outlined;
      title = _who(r);
      lines.add(_when(r.time));
      break;
    case 'refused':
      icon = Icons.block;
      color = error;
      title = translate('funti-journal-refused');
      lines.add([
        _when(r.time),
        _refusedReason(r.alarm),
        if (_who(r).isNotEmpty) _who(r),
        if (r.ip.isNotEmpty && _who(r) != r.ip) r.ip,
      ].join(' · '));
      break;
    case 'admin':
      icon = Icons.build_outlined;
      final key = 'funti-journal-admin-${r.action}';
      final known = translate(key) != key;
      title = translate(known ? key : 'funti-journal-admin-kill')
          .replaceAll('{}', r.name);
      lines.add([
        _when(r.time),
        if (r.peer.isNotEmpty) formatID(r.peer),
        if (r.ip.isNotEmpty) r.ip,
      ].join(' · '));
      break;
    case 'cleared':
      icon = Icons.delete_sweep_outlined;
      title = translate('funti-journal-cleared');
      lines.add(_when(r.time));
      break;
  }
  if (r.received > 0) {
    lines.add(translate('funti-journal-received').replaceAll('{}',
        '${r.received} (${readableFileSize(r.receivedBytes.toDouble())})'));
  }
  if (r.sent > 0) {
    lines.add(translate('funti-journal-sent')
        .replaceAll('{}', '${r.sent} (${readableFileSize(r.sentBytes.toDouble())})'));
  }
  if (r.files.isNotEmpty) lines.add(r.files.join(', '));
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          for (final line in lines)
            Text(line,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: t.muted)),
        ]),
      ),
    ]),
  );
}

/// The journal window: the list, newest first, and "Clear" with a second
/// press to confirm.
void showFuntiJournalDialog() {
  Future<List<FuntiJournalRow>?> rows = _load();
  var confirmClear = false;
  gFFI.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    return CustomAlertDialog(
      title: Text(translate('funti-journal-title')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 560),
      content: SizedBox(
        width: 560,
        height: 420,
        child: FutureBuilder<List<FuntiJournalRow>?>(
          future: rows,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final list = snapshot.data;
            if (list == null || list.isEmpty) {
              return Center(
                  child: Text(
                      translate(list == null
                          ? 'funti-journal-unavailable'
                          : 'funti-journal-empty'),
                      style: TextStyle(color: t.muted)));
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: t.rowStroke),
              itemBuilder: (context, i) => _row(context, list[i]),
            );
          },
        ),
      ),
      actions: [
        dialogButton(
            confirmClear ? 'funti-journal-clear-confirm' : 'funti-journal-clear',
            isOutline: true, onPressed: () {
          setState(() {
            if (confirmClear) rows = _load(clear: true);
            confirmClear = !confirmClear;
          });
        }),
        dialogButton('Close', onPressed: close),
      ],
      onCancel: close,
    );
  });
}
