// FUNTIDESK (ROADMAP, "Полный доступ без сюрпризов"): a copy that is not
// installed cannot click in administrator windows, Windows prompts and on
// the sign-in screen (UIPI). Once, at the first start of such a copy, say so
// plainly and offer to install it (variant Б, 2026-10-13): the same install
// as the "Install" card, which stays on the main screen for later.

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/multi_window_manager.dart';

const String _kOptionAsked = 'funti-full-control-asked';

Future<void> funtiOfferFullControl() async {
  if (!isWindows ||
      bind.isDisableInstallation() ||
      bind.isOutgoingOnly() ||
      bind.mainIsInstalled() ||
      bind.mainGetLocalOption(key: _kOptionAsked) == 'Y') {
    return;
  }
  bind.mainSetLocalOption(key: _kOptionAsked, value: 'Y');
  final res = await gFFI.dialogManager.show<bool>(
      (setState, close, context) => CustomAlertDialog(
            title: Text(translate('funti-full-control-title')),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(translate('funti-full-control-text')),
            ),
            actions: [
              dialogButton('funti-full-control-later',
                  onPressed: close, isOutline: true),
              dialogButton('funti-full-control-allow',
                  onPressed: () => close(true)),
            ],
            onCancel: close,
            onSubmit: () => close(true),
          ));
  if (res != true) return;
  await rustDeskWinManager.closeAllSubWindows();
  bind.mainGotoInstall();
}
