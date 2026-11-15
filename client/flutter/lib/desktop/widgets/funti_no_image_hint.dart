// FUNTIDESK: no picture for a while after connecting. On Windows the usual
// reason is a Remote Desktop (RDP) session of that computer: while its
// window is minimized or disconnected, Windows does not draw the screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';

class FuntiNoImageHint extends StatefulWidget {
  final FFI ffi;
  const FuntiNoImageHint({Key? key, required this.ffi}) : super(key: key);

  @override
  State<FuntiNoImageHint> createState() => _FuntiNoImageHintState();
}

class _FuntiNoImageHintState extends State<FuntiNoImageHint> {
  static const _after = Duration(seconds: 10);
  Timer? _timer;
  bool _late = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_after, () {
      if (mounted) setState(() => _late = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.ffi.ffiModel;
    return Obx(() {
      final waiting = m.pi.isSet.isTrue && m.waitForFirstImage.isTrue;
      if (!_late || !waiting) return const SizedBox.shrink();
      final windows = m.pi.platform == kPeerPlatformWindows;
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
              borderRadius: BorderRadius.circular(10)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.hourglass_empty, color: Colors.white70),
            const SizedBox(height: 8),
            Text(translate('funti-no-image-title'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(translate(windows ? 'funti-no-image-rdp' : 'funti-no-image-other'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ]),
        ),
      );
    });
  }
}
