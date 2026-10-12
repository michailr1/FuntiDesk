// FUNTIDESK (ADR-007): unobtrusive "new version" notice on the main screen.
//
// Checks the same way as "Check for updates" in About: at start and every
// few hours. A failed check shows nothing (the update is optional). A click
// on the notice opens "what's new" of the release; "Later" hides the notice
// until the next version; installing happens only on "Update".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/funti_theme.dart';
import '../../models/platform_model.dart';

const String _kOptionDismissed = 'funti-update-dismissed';
const Duration _kCheckEvery = Duration(hours: 6);

class FuntiUpdateNotice extends StatefulWidget {
  const FuntiUpdateNotice({Key? key}) : super(key: key);

  @override
  State<FuntiUpdateNotice> createState() => _FuntiUpdateNoticeState();
}

class _FuntiUpdateNoticeState extends State<FuntiUpdateNotice> {
  Timer? _timer;
  String _version = '';
  String _unsupported = '';
  String _whatsNew = '';
  bool _expanded = false;
  bool _updating = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_kCheckEvery, (_) => _check());
    // Let the window settle before going to the network.
    Future.delayed(const Duration(seconds: 5), _check);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _updating) return;
    Map<String, dynamic> res;
    try {
      res = jsonDecode(await bind.mainFuntiUpdateCheck());
    } catch (_) {
      return;
    }
    if (!mounted || res['error'] != null || res['available'] != true) return;
    final version = res['version'].toString();
    if (version == bind.mainGetLocalOption(key: _kOptionDismissed)) return;
    if (version == _version) return;
    setState(() {
      _version = version;
      _unsupported = res['unsupported'].toString();
      _whatsNew = '';
      _error = '';
    });
    final text = await bind.mainFuntiWhatsNew();
    if (mounted && version == _version) setState(() => _whatsNew = text);
  }

  void _later() {
    bind.mainSetLocalOption(key: _kOptionDismissed, value: _version);
    setState(() => _version = '');
  }

  Future<void> _update() async {
    setState(() {
      _updating = true;
      _error = '';
    });
    final err = await bind.mainFuntiUpdateStart();
    if (!mounted || err.isEmpty) return;
    setState(() {
      _updating = false;
      _error = translate('funti-update-failed')
          .replaceAll('{}', translate(err));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_version.isEmpty) return const SizedBox.shrink();
    final t = FuntiTokens.of(context);
    final canUpdate = _unsupported.isEmpty;
    final muted = TextStyle(fontSize: 13, color: t.muted);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.stroke),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(children: [
                Icon(Icons.system_update_alt_rounded, color: t.accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          translate('funti-update-notice')
                              .replaceAll('{}', _version),
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: t.text)),
                      Text(
                          translate(_expanded
                              ? 'funti-update-notice-hide'
                              : 'funti-update-notice-more'),
                          style: TextStyle(fontSize: 13, color: t.link)),
                    ],
                  ),
                ),
                if (_updating)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else ...[
                  TextButton(
                      onPressed: _later,
                      child: Text(translate('funti-update-later'))),
                  if (canUpdate)
                    ElevatedButton(
                        onPressed: _update,
                        child: Text(translate('funti-update-now'))),
                ],
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        color: t.muted)
                    .marginOnly(left: 6),
              ]),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      child: SelectableText(
                          _whatsNew.isEmpty
                              ? translate('funti-update-no-notes')
                              : _whatsNew,
                          style: TextStyle(
                              fontSize: 14, height: 1.45, color: t.text)),
                    ),
                  ),
                  if (!canUpdate)
                    Text(translate(_unsupported), style: muted)
                        .marginOnly(top: 8),
                ],
              ),
            ),
          if (_updating || _error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 16, 12),
              child: Text(
                  _updating ? translate('funti-update-progress') : _error,
                  style: muted),
            ),
        ],
      ),
    );
  }
}
