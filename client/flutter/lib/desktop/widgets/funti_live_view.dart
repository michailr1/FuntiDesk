// FUNTIDESK (ADR-024, stage 3b): a control session inside a tile of the
// workplace — the same session as the screen window (FFI, ImagePaint,
// input), without the window, the toolbar and the window events. One at a
// time; the keyboard goes to it only while it has the focus.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/shared_state.dart';
import '../../common/widgets/remote_input.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../pages/remote_page.dart' show ImagePaint, CursorPaint;

class FuntiLiveView extends StatefulWidget {
  final String id;

  /// The first picture arrived: the tile may stop showing the still one.
  final VoidCallback? onFirstImage;
  const FuntiLiveView({Key? key, required this.id, this.onFirstImage})
      : super(key: key);

  @override
  State<FuntiLiveView> createState() => FuntiLiveViewState();
}

class FuntiLiveViewState extends State<FuntiLiveView> {
  late final FFI ffi;
  final _focus = FocusNode(debugLabel: 'funti-live');
  final _cursorOverImage = false.obs;
  late RxBool _zoomCursor, _showRemoteCursor, _keyboardEnabled, _remoteCursorMoved;
  Size? _size;
  bool _sizeScheduled = false;

  String get id => widget.id;

  @override
  void initState() {
    super.initState();
    initSharedStates(id);
    ffi = FFI(null);
    Get.put<FFI>(ffi, tag: id);
    _zoomCursor = PeerBoolOption.find(id, kOptionZoomCursor);
    _showRemoteCursor = ShowRemoteCursorState.find(id);
    _keyboardEnabled = KeyboardEnabledState.find(id);
    _remoteCursorMoved = RemoteCursorMovedState.find(id);
    ffi.imageModel.addCallbackOnFirstImage((_) {
      ffi.canvasModel.activateLocalCursor();
      widget.onFirstImage?.call();
    });
    ffi.start(id);
    ffi.ffiModel.updateEventListener(ffi.sessionId, id);
  }

  @override
  void dispose() {
    bind.hostStopSystemKeyPropagate(stopped: true);
    ffi.textureModel.onRemotePageDispose(true);
    ffi.inputModel.enterOrLeave(false);
    ffi.imageModel.disposeImage();
    ffi.cursorModel.disposeImages();
    _focus.dispose();
    ffi.close();
    ffi.dialogManager.dismissAll();
    Get.delete<FFI>(tag: id);
    removeSharedStates(id);
    super.dispose();
  }

  void ctrlAltDel() => bind.sessionCtrlAltDel(sessionId: ffi.sessionId);

  /// The canvas follows the size of the tile, as the screen window does.
  void _trackSize(Size size) {
    if (_size == size) return;
    _size = size;
    if (_sizeScheduled) return;
    _sizeScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _sizeScheduled = false;
      final s = _size;
      if (mounted && s != null) {
        ffi.canvasModel.updateViewStyle();
        ffi.inputModel.updateImageWidgetSize(s);
      }
    });
  }

  Widget _input(Widget child) => RawTouchGestureDetectorRegion(
        ffi: ffi,
        child: RawPointerMouseRegion(
          inputModel: ffi.inputModel,
          onEnter: (_) {
            _cursorOverImage.value = true;
            ffi.canvasModel.rearmEdgeScroll();
          },
          onExit: (e) {
            _cursorOverImage.value = false;
            ffi.canvasModel.disableEdgeScroll();
          },
          onPointerDown: (_) {
            if (!_focus.hasFocus) _focus.requestFocus();
          },
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ffi.ffiModel),
        ChangeNotifierProvider.value(value: ffi.imageModel),
        ChangeNotifierProvider.value(value: ffi.cursorModel),
        ChangeNotifierProvider.value(value: ffi.canvasModel),
      ],
      child: Container(
        color: kColorCanvas,
        child: RawKeyFocusScope(
          focusNode: _focus,
          inputModel: ffi.inputModel,
          onFocusChange: (focused) => ffi.inputModel.enterOrLeave(focused),
          child: MouseRegion(
            onEnter: (_) => bind.hostStopSystemKeyPropagate(stopped: false),
            onExit: (_) => bind.hostStopSystemKeyPropagate(stopped: true),
            child: LayoutBuilder(builder: (context, constraints) {
              if (constraints.maxWidth.isFinite && constraints.maxHeight.isFinite) {
                _trackSize(Size(constraints.maxWidth, constraints.maxHeight));
              }
              final peerDisplay = CurrentDisplayState.find(id);
              return Stack(children: [
                Obx(() {
                  if (ffi.ffiModel.pi.isSet.isFalse) {
                    return Container(color: Colors.transparent);
                  }
                  ffi.textureModel.updateCurrentDisplay(peerDisplay.value);
                  return ImagePaint(
                    id: id,
                    ffi: ffi,
                    zoomCursor: _zoomCursor,
                    cursorOverImage: _cursorOverImage,
                    keyboardEnabled: _keyboardEnabled,
                    remoteCursorMoved: _remoteCursorMoved,
                    listenerBuilder: _input,
                  );
                }),
                if (!ffi.canvasModel.cursorEmbedded)
                  Obx(() => _showRemoteCursor.isFalse || _remoteCursorMoved.isFalse
                      ? const Offstage()
                      : CursorPaint(id: id, zoomCursor: _zoomCursor)),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}
