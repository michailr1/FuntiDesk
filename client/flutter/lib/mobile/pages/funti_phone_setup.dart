// FUNTIDESK (ADR-026): prepare a phone once so that the helper can connect
// without anyone at it — every permission in one list, each with one
// button, and what is already done is shown as done. Android still asks
// once to share the screen each time the sharing starts (after a restart):
// no app can skip that.

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../desktop/widgets/funti_family.dart';
import '../../models/platform_model.dart';

const kFuntiPhoneSetupDone = 'funti-phone-setup-done';

class _Step {
  final String key;
  final bool done;
  final Future<void> Function() act;
  _Step(this.key, this.done, this.act);
}

class FuntiPhoneSetupPage extends StatefulWidget {
  const FuntiPhoneSetupPage({Key? key}) : super(key: key);

  @override
  State<FuntiPhoneSetupPage> createState() => _FuntiPhoneSetupPageState();
}

class _FuntiPhoneSetupPageState extends State<FuntiPhoneSetupPage>
    with WidgetsBindingObserver {
  bool _battery = false, _overlay = false, _boot = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the system settings: see what was allowed there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final battery = await AndroidPermissionManager.check(kRequestIgnoreBatteryOptimizations);
    final overlay = await AndroidPermissionManager.check(kSystemAlertWindow);
    final boot = await gFFI.invokeMethod(AndroidChannel.kGetStartOnBootOpt) == true;
    if (mounted) {
      setState(() {
        _battery = battery;
        _overlay = overlay;
        _boot = boot && battery && overlay;
      });
    }
  }

  List<_Step> _steps() {
    final server = gFFI.serverModel;
    return [
      _Step('funti-setup-battery', _battery, () async {
        await AndroidPermissionManager.request(kRequestIgnoreBatteryOptimizations);
        await _check();
      }),
      _Step('funti-setup-overlay', _overlay, () async {
        await AndroidPermissionManager.request(kSystemAlertWindow);
        await _check();
      }),
      _Step('funti-setup-boot', _boot, () async {
        if (!_battery || !_overlay) {
          showToast(translate('funti-setup-boot-first'));
          return;
        }
        await gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, true);
        await _check();
      }),
      _Step('funti-setup-input', server.inputOk, () async {
        if (!server.inputOk) await server.toggleInput();
      }),
      _Step('funti-setup-family', funtiFamilyMembers().isNotEmpty, () async {
        showFuntiFamilyCodeDialog(onChanged: () => setState(() {}));
      }),
      _Step('funti-setup-service', server.isStart, () async {
        if (!server.isStart) await server.toggleService();
      }),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(translate('funti-setup-title'))),
      // Rebuilt when the server state changes (service, input).
      body: AnimatedBuilder(animation: gFFI.serverModel, builder: (context, _) {
        final steps = _steps();
        final left = steps.where((s) => !s.done).length;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text(translate('funti-setup-intro')),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            Card(
              child: ListTile(
                leading: Icon(
                    steps[i].done ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: steps[i].done ? Colors.green : null),
                title: Text('${i + 1}. ${translate('${steps[i].key}')}'),
                subtitle: Text(translate('${steps[i].key}-why')),
                trailing: steps[i].done
                    ? null
                    : ElevatedButton(
                        onPressed: steps[i].act,
                        child: Text(translate('funti-setup-do'))),
              ),
            ),
          const SizedBox(height: 12),
          Text(
              left == 0
                  ? translate('funti-setup-ready')
                  : translate('funti-setup-left').replaceAll('{}', '$left'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(translate('funti-setup-android-note'),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          ElevatedButton(
              onPressed: () {
                bind.mainSetLocalOption(key: kFuntiPhoneSetupDone, value: 'Y');
                Navigator.pop(context);
              },
              child: Text(translate(left == 0 ? 'funti-setup-finish' : 'funti-setup-later'))),
        ]);
      }),
    );
  }
}

/// Opens the setup once, the first time the app starts on a phone.
void funtiPhoneSetupOnFirstStart(BuildContext context) {
  if (bind.mainGetLocalOption(key: kFuntiPhoneSetupDone) == 'Y') return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const FuntiPhoneSetupPage()));
  });
}
