// FUNTIDESK (ADR-006): family access — the family list kept by the service
// and the two pairing dialogs: show this computer's one-time code, or enter
// the code shown on another computer.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../models/platform_model.dart';

const String kFuntiOptionFamily = 'funti-family';

class FuntiFamilyMember {
  const FuntiFamilyMember(
      {required this.id, required this.name, required this.pk});

  final String id;
  final String name;
  final String pk;

  factory FuntiFamilyMember.fromJson(Map<String, dynamic> json) =>
      FuntiFamilyMember(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        pk: (json['pk'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pk': pk};

  String get title => name.isEmpty ? formatFuntiId(id) : name;

  @override
  bool operator ==(Object other) =>
      other is FuntiFamilyMember &&
      other.id == id &&
      other.name == name &&
      other.pk == pk;

  @override
  int get hashCode => Object.hash(id, name, pk);
}

String formatFuntiId(String id) {
  final digits = id.replaceAll(' ', '');
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return buf.toString();
}

List<FuntiFamilyMember> funtiFamilyMembers() {
  try {
    final raw = bind.mainGetOptionSync(key: kFuntiOptionFamily);
    if (raw.isEmpty) return [];
    final list = jsonDecode(raw);
    if (list is! List) return [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(FuntiFamilyMember.fromJson)
        .where((m) => m.id.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> funtiFamilyRemove(String id) async {
  final rest = funtiFamilyMembers().where((m) => m.id != id).toList();
  await bind.mainSetOption(
      key: kFuntiOptionFamily,
      value: jsonEncode(rest.map((m) => m.toJson()).toList()));
}

/// "Add to family": choose between showing this computer's code and entering
/// another computer's code.
void showFuntiFamilyAddDialog({VoidCallback? onChanged}) {
  gFFI.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    Widget choice(IconData icon, String title, String text, VoidCallback on) =>
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: on,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: t.stroke),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(icon, color: t.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: t.text)),
                      const SizedBox(height: 4),
                      Text(text,
                          style: TextStyle(fontSize: 13, color: t.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return CustomAlertDialog(
      title: Text(translate('funti-family-add')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 460),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate('funti-family-add-text'),
              style: TextStyle(fontSize: 13, color: t.muted)),
          const SizedBox(height: 16),
          choice(
              Icons.pin_outlined,
              translate('funti-family-show-code'),
              translate('funti-family-show-code-text'), () {
            close();
            _showCodeDialog(onChanged);
          }),
          const SizedBox(height: 10),
          choice(
              Icons.keyboard_outlined,
              translate('funti-family-enter-code'),
              translate('funti-family-enter-code-text'), () {
            close();
            _enterCodeDialog(onChanged);
          }),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
      ],
      onCancel: close,
    );
  });
}

void _showCodeDialog(VoidCallback? onChanged) {
  final code = bind.mainFuntiFamilyCode(start: true);
  final before = funtiFamilyMembers().map((m) => m.id).toSet();
  final added = Rxn<FuntiFamilyMember>();
  Timer? timer;
  gFFI.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      final now = funtiFamilyMembers();
      final fresh = now.where((m) => !before.contains(m.id));
      if (fresh.isNotEmpty && added.value == null) {
        added.value = fresh.first;
        onChanged?.call();
      }
    });
    void done() {
      timer?.cancel();
      if (added.value == null) bind.mainFuntiFamilyCode(start: false);
      close();
    }

    return CustomAlertDialog(
      title: Text(translate('funti-family-show-code')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 460),
      content: FutureBuilder<String>(
        future: code,
        builder: (context, snap) {
          final value = snap.data ?? '';
          return Obx(() {
            final member = added.value;
            if (member != null) {
              return Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: t.ok, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      translate('funti-family-added')
                          .replaceAll('{}', member.title),
                      style: TextStyle(fontSize: 15, color: t.text),
                    ),
                  ),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(translate('funti-family-show-code-hint'),
                    style: TextStyle(fontSize: 13, color: t.muted)),
                const SizedBox(height: 18),
                Center(
                  child: snap.connectionState != ConnectionState.done
                      ? const CircularProgressIndicator()
                      : value.length == 6
                          ? SelectableText(
                              '${value.substring(0, 3)} ${value.substring(3)}',
                              style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 4,
                                color: t.text,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            )
                          : Text(translate('funti-family-service-error'),
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                ),
                const SizedBox(height: 18),
                Text(
                  '${translate('funti-family-this-id')}: '
                  '${formatFuntiId(gFFI.serverModel.serverId.text)}',
                  style: TextStyle(fontSize: 13, color: t.muted),
                ),
              ],
            );
          });
        },
      ),
      actions: [
        Obx(() => dialogButton(added.value == null ? 'Cancel' : 'OK',
            onPressed: done, isOutline: added.value == null)),
      ],
      onCancel: done,
      onSubmit: done,
    );
  });
}

void _enterCodeDialog(VoidCallback? onChanged) {
  final idController = TextEditingController();
  final codeController = TextEditingController();
  final busy = false.obs;
  final error = ''.obs;
  final added = ''.obs;
  gFFI.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    Future<void> submit() async {
      if (added.value.isNotEmpty) {
        close();
        return;
      }
      final id = idController.text.replaceAll(' ', '');
      final code = codeController.text.replaceAll(' ', '');
      if (id.isEmpty || code.length != 6) {
        error.value = translate('funti-family-enter-both');
        return;
      }
      busy.value = true;
      error.value = '';
      final res = jsonDecode(await bind.mainFuntiFamilyPair(id: id, code: code))
          as Map<String, dynamic>;
      busy.value = false;
      if (res['name'] != null) {
        added.value = res['name'].toString();
        onChanged?.call();
      } else {
        final e = (res['error'] ?? '').toString();
        error.value = e == 'funti-family-pair-failed'
            ? translate('funti-family-code-wrong')
            : e == 'timeout' || e == 'connection closed'
                // An older FuntiDesk ignores the pairing request.
                ? translate('funti-family-no-answer')
                : '${translate('funti-family-pair-error')} $e';
      }
    }

    return CustomAlertDialog(
      title: Text(translate('funti-family-enter-code')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 460),
      content: Obx(() {
        if (added.value.isNotEmpty) {
          return Row(
            children: [
              Icon(Icons.check_circle_rounded, color: t.ok, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  translate('funti-family-added')
                      .replaceAll('{}', added.value),
                  style: TextStyle(fontSize: 15, color: t.text),
                ),
              ),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('funti-family-enter-code-hint'),
                style: TextStyle(fontSize: 13, color: t.muted)),
            const SizedBox(height: 14),
            TextField(
              controller: idController,
              autofocus: true,
              enabled: !busy.value,
              decoration: InputDecoration(
                  labelText: translate('funti-family-their-id')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: codeController,
              enabled: !busy.value,
              maxLength: 7,
              decoration: InputDecoration(
                  labelText: translate('funti-family-code'), counterText: ''),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 8),
            if (busy.value) const LinearProgressIndicator(),
            if (error.value.isNotEmpty)
              Text(error.value,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.error)),
          ],
        );
      }),
      actions: [
        Obx(() => added.value.isEmpty
            ? dialogButton('Cancel', onPressed: close, isOutline: true)
            : const SizedBox.shrink()),
        Obx(() => dialogButton(added.value.isEmpty ? 'funti-family-pair' : 'OK',
            onPressed: busy.value ? null : submit)),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

/// Helper side: "<name> asks for help" with "Connect".
void showFuntiHelpRequestDialog(String id, String name) {
  final known = funtiFamilyMembers().where((m) => m.id == id).toList();
  final title = name.isNotEmpty
      ? name
      : known.isNotEmpty
          ? known.first.title
          : formatFuntiId(id);
  gFFI.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    void go() {
      close();
      connect(context, id);
    }

    return CustomAlertDialog(
      title: Row(
        children: [
          Icon(Icons.support_agent_rounded, color: t.accent),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  translate('funti-help-incoming').replaceAll('{}', title))),
        ],
      ),
      contentBoxConstraints: const BoxConstraints(maxWidth: 460),
      content: Text(translate('funti-help-incoming-text'),
          style: TextStyle(fontSize: 14, color: t.muted)),
      actions: [
        dialogButton('funti-help-later', onPressed: close, isOutline: true),
        dialogButton('funti-help-connect', onPressed: go),
      ],
      onSubmit: go,
      onCancel: close,
    );
  }, tag: 'funti-help-$id');
}

/// Asking side: send the request to every family member, show who got it.
void showFuntiAskHelpDialog() {
  final members = funtiFamilyMembers();
  // id -> null (sending), '' (delivered), error
  final status = <String, String?>{for (final m in members) m.id: null}.obs;
  for (final m in members) {
    bind.mainFuntiFamilyHelp(id: m.id).then((res) {
      String result = '';
      try {
        final json = jsonDecode(res) as Map<String, dynamic>;
        result = (json['error'] ?? '').toString();
      } catch (_) {
        result = 'error';
      }
      status[m.id] = result;
    });
  }
  gFFI.dialogManager.show((setState, close, context) {
    final t = FuntiTokens.of(context);
    return CustomAlertDialog(
      title: Text(translate('funti-help-ask')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 460),
      content: Obx(() {
        final delivered = status.values.where((v) => v == '').length;
        final pending = status.values.where((v) => v == null).length;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in members)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: status[m.id] == null
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(
                              status[m.id] == ''
                                  ? Icons.check_circle_rounded
                                  : Icons.remove_circle_outline_rounded,
                              size: 18,
                              color: status[m.id] == '' ? t.ok : t.muted),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(m.title,
                            style: TextStyle(fontSize: 15, color: t.text))),
                    Text(
                      status[m.id] == null
                          ? translate('funti-help-sending')
                          : status[m.id] == ''
                              ? translate('funti-help-delivered')
                              : translate('funti-help-not-delivered'),
                      style: TextStyle(fontSize: 13, color: t.muted),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              pending > 0
                  ? translate('funti-help-wait-send')
                  : delivered > 0
                      ? translate('funti-help-wait-connect')
                      : translate('funti-help-nobody'),
              style: TextStyle(fontSize: 13, color: t.muted),
            ),
          ],
        );
      }),
      actions: [dialogButton('OK', onPressed: close)],
      onSubmit: close,
      onCancel: close,
    );
  });
}
