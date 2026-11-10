import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:extended_text/extended_text.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/desktop/widgets/dragable_divider.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hbb/desktop/widgets/list_search_action_listener.dart';
import 'package:flutter_hbb/desktop/widgets/menu_button.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_hbb/web/dummy.dart'
    if (dart.library.html) 'package:flutter_hbb/web/web_unique.dart';

import '../../consts.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/funti_folder_tree.dart';
import '../widgets/popup_menu.dart';

/// status of location bar
enum LocationStatus {
  /// normal bread crumb bar
  bread,

  /// show path text field
  pathLocation,

  /// show file search bar text field
  fileSearchBar
}

/// The status of currently focused scope of the mouse
enum MouseFocusScope {
  /// Mouse is in local field.
  local,

  /// Mouse is in remote field.
  remote,

  /// Mouse is not in local field, remote neither.
  none
}

class FileManagerPage extends StatefulWidget {
  FileManagerPage(
      {Key? key,
      required this.id,
      required this.password,
      this.loginMethod = '',
      required this.isSharedPassword,
      this.tabController,
      this.connToken,
      this.forceRelay})
      : super(key: key);
  final String id;
  final String? password;
  final String loginMethod;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;
  final DesktopTabController? tabController;
  final SimpleWrapper<State<FileManagerPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _FileManagerPageState)._ffi;

  @override
  State<StatefulWidget> createState() {
    final state = _FileManagerPageState();
    _lastState.value = state;
    return state;
  }
}

class _FileManagerPageState extends State<FileManagerPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _mouseFocusScope = Rx<MouseFocusScope>(MouseFocusScope.none);

  final _dropMaskVisible = false.obs; // TODO impl drop mask
  final _overlayKeyState = OverlayKeyState();
  final _uniqueKey = UniqueKey();

  late FFI _ffi;

  FileModel get model => _ffi.fileModel;
  JobController get jobController => model.jobController;

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    _ffi.start(widget.id,
        isFileTransfer: true,
        password: widget.password,
        loginMethod: widget.loginMethod,
        isSharedPassword: widget.isSharedPassword,
        connToken: widget.connToken,
        forceRelay: widget.forceRelay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    Get.put<FFI>(_ffi, tag: 'ft_${widget.id}');
    WakelockManager.enable(_uniqueKey);
    if (isWeb) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
    debugPrint("File manager page init success with id ${widget.id}");
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    model.close().whenComplete(() {
      _ffi.close();
      _ffi.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
      Get.delete<FFI>(tag: 'ft_${widget.id}');
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      jobController.jobTable.refresh();
    }
  }

  Widget willPopScope(Widget child) {
    if (isWeb) {
      return WillPopScope(
        onWillPop: () async {
          clientClose(_ffi.sessionId, _ffi);
          return false;
        },
        child: child,
      );
    } else {
      return child;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(key: _overlayKeyState.key, initialEntries: [
      OverlayEntry(builder: (_) {
        return willPopScope(Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Row(
            children: [
              if (!isWeb)
                Flexible(
                    flex: 3,
                    child: dropArea(FileManagerView(
                        model.localController, _ffi, _mouseFocusScope))),
              Flexible(
                  flex: 3,
                  child: dropArea(FileManagerView(
                      model.remoteController, _ffi, _mouseFocusScope))),
              Flexible(flex: 2, child: statusList())
            ],
          ),
        ));
      })
    ]);
  }

  Widget dropArea(FileManagerView fileView) {
    return DropTarget(
        onDragDone: (detail) =>
            handleDragDone(detail, fileView.controller.isLocal),
        onDragEntered: (enter) {
          _dropMaskVisible.value = true;
        },
        onDragExited: (exit) {
          _dropMaskVisible.value = false;
        },
        child: fileView);
  }

  Widget generateCard(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.all(
          Radius.circular(15.0),
        ),
      ),
      child: child,
    );
  }

  /// transfer status list
  /// watch transfer status
  Widget statusList() {
    Widget getIcon(JobProgress job) {
      final color = Theme.of(context).tabBarTheme.labelColor;
      switch (job.type) {
        case JobType.deleteDir:
        case JobType.deleteFile:
          return Icon(Icons.delete_outline, color: color);
        default:
          return Transform.rotate(
            angle: isWeb
                ? job.isRemoteToLocal
                    ? pi / 2
                    : pi / 2 * 3
                : job.isRemoteToLocal
                    ? pi
                    : 0,
            child: Icon(Icons.arrow_forward_ios, color: color),
          );
      }
    }

    statusListView(List<JobProgress> jobs) => ListView.builder(
          controller: ScrollController(),
          itemBuilder: (BuildContext context, int index) {
            final item = jobs[index];
            final status = item.getStatus();
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: generateCard(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        getIcon(item)
                            .marginSymmetric(horizontal: 10, vertical: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                waitDuration: Duration(milliseconds: 500),
                                message: item.jobName,
                                child: ExtendedText(
                                  item.jobName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  overflowWidget: TextOverflowWidget(
                                      child: Text("..."),
                                      position: TextOverflowPosition.start),
                                ),
                              ),
                              Tooltip(
                                waitDuration: Duration(milliseconds: 500),
                                message: status,
                                child: Text(status,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: MyTheme.darkGray,
                                    )).marginOnly(top: 6),
                              ),
                              Offstage(
                                offstage: item.type != JobType.transfer ||
                                    item.state != JobState.inProgress,
                                child: LinearPercentIndicator(
                                  animateFromLastPercent: true,
                                  center: SizedBox.expand(
                                    child: ShaderMask(
                                      blendMode: BlendMode.srcATop,
                                      shaderCallback: (bounds) =>
                                          LinearGradient(
                                        colors: [
                                          Colors.white,
                                          Colors.transparent,
                                        ],
                                        stops: [item.percent, item.percent],
                                      ).createShader(bounds),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text.rich(
                                          TextSpan(
                                            text: item.percentText,
                                            children: [
                                              if (item.recvJobRes)
                                                TextSpan(
                                                  text:
                                                      ' ${readableFileSize(item.speed)}/s',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w300,
                                                    color: MyTheme.darkGray,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  barRadius: Radius.circular(15),
                                  percent: item.percent,
                                  progressColor: MyTheme.accent,
                                  backgroundColor: Theme.of(context).hoverColor,
                                  lineHeight: kDesktopFileTransferRowHeight,
                                ).paddingSymmetric(vertical: 8),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (!isWeb &&
                                item.type == JobType.transfer &&
                                item.isRemoteToLocal &&
                                item.state == JobState.done &&
                                item.err.isEmpty &&
                                item.to.isNotEmpty)
                              MenuButton(
                                tooltip: translate('funti-ft-show-in-folder'),
                                onPressed: () => _funtiShowInFolder(item.to),
                                child: Icon(Icons.folder_open_rounded,
                                    color: Colors.white, size: 18),
                                color: MyTheme.accent,
                                hoverColor: MyTheme.accent80,
                              ).marginOnly(right: 8),
                            Offstage(
                              offstage: item.state != JobState.paused,
                              child: MenuButton(
                                tooltip: translate("Resume"),
                                onPressed: () {
                                  jobController.resumeJob(item.id);
                                },
                                child: SvgPicture.asset(
                                  "assets/refresh.svg",
                                  colorFilter: svgColor(Colors.white),
                                ),
                                color: MyTheme.accent,
                                hoverColor: MyTheme.accent80,
                              ),
                            ),
                            MenuButton(
                              tooltip: translate("Delete"),
                              child: SvgPicture.asset(
                                "assets/close.svg",
                                colorFilter: svgColor(Colors.white),
                              ),
                              onPressed: () {
                                jobController.jobTable.removeAt(index);
                                jobController.cancelJob(item.id);
                              },
                              color: MyTheme.accent,
                              hoverColor: MyTheme.accent80,
                            ),
                          ],
                        ).marginAll(12),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          itemCount: jobController.jobTable.length,
        );

    return PreferredSize(
      preferredSize: const Size(200, double.infinity),
      child: Container(
          margin: const EdgeInsets.only(top: 16.0, bottom: 16.0, right: 16.0),
          padding: const EdgeInsets.all(8.0),
          child: Obx(
            () => jobController.jobTable.isEmpty
                ? generateCard(
                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SvgPicture.asset(
                            "assets/transfer.svg",
                            colorFilter: svgColor(
                                Theme.of(context).tabBarTheme.labelColor),
                            height: 40,
                          ).paddingOnly(bottom: 10),
                          Text(
                            translate("No transfers in progress"),
                            textAlign: TextAlign.center,
                            textScaler: TextScaler.linear(1.20),
                            style: TextStyle(
                                color:
                                    Theme.of(context).tabBarTheme.labelColor),
                          ),
                        ],
                      ),
                    ),
                  )
                : statusListView(jobController.jobTable),
          )),
    );
  }

  void handleDragDone(DropDoneDetails details, bool isLocal) {
    if (isLocal) {
      // ignore local
      return;
    }
    final items = SelectedItems(isLocal: false);
    for (var file in details.files) {
      final f = File(file.path);
      items.add(Entry()
        ..path = file.path
        ..name = file.name
        ..size = FileSystemEntity.isDirectorySync(f.path) ? 0 : f.lengthSync());
    }
    final otherSideData = model.localController.directoryData();
    model.remoteController.sendFiles(items, otherSideData);
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final FFI _ffi;
  final Rx<MouseFocusScope> _mouseFocusScope;

  FileManagerView(this.controller, this._ffi, this._mouseFocusScope);

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _locationStatus = LocationStatus.bread.obs;
  final _locationNode = FocusNode();
  final _locationBarKey = GlobalKey();
  final _searchText = "".obs;
  final _breadCrumbScroller = ScrollController();
  final _keyboardNode = FocusNode();
  final _listSearchBuffer = TimeoutStringBuffer();
  final _nameColWidth = 0.0.obs;
  final _modifiedColWidth = 0.0.obs;
  final _sizeColWidth = 0.0.obs;
  final _fileListScrollController = ScrollController();
  final _globalHeaderKey = GlobalKey();

  /// [_lastClickTime], [_lastClickEntry] help to handle double click
  var _lastClickTime =
      DateTime.now().millisecondsSinceEpoch - bind.getDoubleClickTime() - 1000;
  Entry? _lastClickEntry;

  double? _windowWidthPrev;
  double _fileTransferMinimumWidth = 0.0;

  FileController get controller => widget.controller;
  bool get isLocal => widget.controller.isLocal;
  FFI get _ffi => widget._ffi;
  SelectedItems get selectedItems => controller.selectedItems;

  @override
  void initState() {
    super.initState();
    // register location listener
    _locationNode.addListener(onLocationFocusChanged);
    controller.directory.listen((e) => breadCrumbScrollToEnd());
  }

  @override
  void dispose() {
    _locationNode.removeListener(onLocationFocusChanged);
    _locationNode.dispose();
    _keyboardNode.dispose();
    _breadCrumbScroller.dispose();
    _fileListScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _handleColumnPorportions();
    return Container(
      margin: const EdgeInsets.all(16.0),
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          headTools(),
          Expanded(
            child: _withFolderTree(Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: MouseRegion(
                  onEnter: (evt) {
                    widget._mouseFocusScope.value = isLocal
                        ? MouseFocusScope.local
                        : MouseFocusScope.remote;
                    // FUNTIDESK: moving the mouse over the list must not
                    // take the focus from the address bar being typed in.
                    if (!_isTyping()) _keyboardNode.requestFocus();
                  },
                  onExit: (evt) =>
                      widget._mouseFocusScope.value = MouseFocusScope.none,
                  child: _funtiShortcuts(Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onFileListKeyEvent,
                    child: _buildFileList(context, _fileListScrollController),
                  )),
                ))
              ],
            )),
          ),
          _funtiStatusBar(),
        ],
      ),
    );
  }

  void _handleColumnPorportions() {
    final windowWidthNow = MediaQuery.of(context).size.width;
    if (_windowWidthPrev == null) {
      _windowWidthPrev = windowWidthNow;
      final defaultColumnWidth = windowWidthNow * 0.115;
      _fileTransferMinimumWidth = defaultColumnWidth / 3;
      _nameColWidth.value = defaultColumnWidth;
      _modifiedColWidth.value = defaultColumnWidth;
      _sizeColWidth.value = defaultColumnWidth;
    }

    if (_windowWidthPrev != windowWidthNow) {
      final difference = windowWidthNow / _windowWidthPrev!;
      _windowWidthPrev = windowWidthNow;
      _fileTransferMinimumWidth *= difference;
      _nameColWidth.value *= difference;
      _modifiedColWidth.value *= difference;
      _sizeColWidth.value *= difference;
    }
  }

  bool _isTyping() {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null ||
        focus?.context?.widget is EditableText;
  }

  Future<void> _openTyped(String path) async {
    path = path.trim();
    if (path.isEmpty) return;
    selectedItems.clear();
    if (!await controller.openDirectory(path)) {
      showToast(translate('funti-ft-open-failed').replaceAll('{}', path));
    }
  }

  // FUNTIDESK: folder tree on the left as in Explorer for Windows sides
  // (quick folders and "This PC"; owner's decisions 2026-10-08, 2026-10-11).
  // Variables are expanded on the side that owns the files.
  Widget _withFolderTree(Widget list) {
    // The platform as in the panel header: options.isWindows is filled in
    // later without notifying, so the tree stayed hidden after reconnecting.
    return FutureBuilder<String>(
        future: bind.sessionGetPlatform(
            sessionId: _ffi.sessionId, isRemote: !isLocal),
        builder: (context, snapshot) {
      if (snapshot.data != kPeerPlatformWindows) return list;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 200,
            child: FuntiFolderTree(controller: controller, onOpen: _openTyped),
          ),
          const VerticalDivider(width: 9),
          Expanded(child: list),
        ],
      ).marginOnly(top: 8);
    });
  }

  // FUNTIDESK: keys as in Explorer (owner's request 2026-11-03): Ctrl+C and
  // Ctrl+V between the panels, Delete, F2 to rename. Ctrl+V on the remote
  // panel also pastes the files copied on this computer (Explorer).
  Widget _funtiShortcuts(Widget list) {
    if (isWeb) return list;
    void run(void Function() action) {
      if (!_isTyping()) action();
    }

    return CallbackShortcuts(bindings: {
      SingleActivator(LogicalKeyboardKey.keyC,
          control: !isMacOS,
          meta: isMacOS,
          includeRepeats: false): () => run(_funtiCopy),
      SingleActivator(LogicalKeyboardKey.keyV,
          control: !isMacOS,
          meta: isMacOS,
          includeRepeats: false): () => run(_funtiPaste),
      const SingleActivator(LogicalKeyboardKey.delete, includeRepeats: false):
          () => run(_funtiDelete),
      const SingleActivator(LogicalKeyboardKey.f2, includeRepeats: false): () =>
          run(_funtiRename),
      SingleActivator(LogicalKeyboardKey.keyC,
          control: !isMacOS,
          meta: isMacOS,
          shift: true,
          includeRepeats: false): () => run(_funtiCopyPath),
      SingleActivator(LogicalKeyboardKey.keyA,
              control: !isMacOS, meta: isMacOS, includeRepeats: false):
          () => run(() => setState(() => selectedItems.selectAll(_funtiVisible))),
      const SingleActivator(LogicalKeyboardKey.backspace): () => run(() {
            selectedItems.clear();
            controller.openDirectory('..');
          }),
      const SingleActivator(LogicalKeyboardKey.f5): () =>
          run(() => controller.refresh()),
    }, child: list);
  }

  String get _funtiCmd => isMacOS ? '⌘' : 'Ctrl+';

  // FUNTIDESK (ADR-017): "Pictures" mode — taller rows with previews,
  // remembered for each panel.
  String get _funtiThumbsKey =>
      isLocal ? 'funti-ft-thumbs-local' : 'funti-ft-thumbs-remote';
  late final _funtiThumbs =
      (!isWeb && bind.mainGetLocalOption(key: _funtiThumbsKey) == 'Y').obs;
  static const _funtiThumbRowHeight = 56.0;
  double get _funtiRowHeight => _funtiThumbs.value
      ? _funtiThumbRowHeight
      : kDesktopFileTransferRowHeight;

  void _funtiToggleThumbs() {
    _funtiThumbs.value = !_funtiThumbs.value;
    bind.mainSetLocalOption(
        key: _funtiThumbsKey, value: _funtiThumbs.value ? 'Y' : '');
  }

  Widget _funtiIcon(Entry entry) {
    final icon = SvgPicture.asset(
      entry.isFile ? "assets/file.svg" : "assets/folder.svg",
      colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
    );
    if (!_funtiThumbs.value || !entry.isFile || !funtiIsPicture(entry.name)) {
      return icon;
    }
    return _FuntiThumb(
        key: ValueKey(entry.path),
        entry: entry,
        isLocal: isLocal,
        thumbs: _ffi.fileModel.funtiThumbs,
        fallback: icon);
  }

  List<Entry> get _funtiSelection =>
      selectedItems.items.where((e) => !e.isDrive).toList();

  // On Windows, "/" is the list of drives, not a folder.
  bool _funtiFolderOpen(DirectoryData data) {
    final path = data.directory.path;
    return path.isNotEmpty && !(data.options.isWindows && path == '/');
  }

  // The rows as shown: the list filtered by the search field.
  List<Entry> get _funtiVisible {
    final entries = controller.directory.value.entries;
    if (_searchText.isEmpty) return entries;
    return entries.where((e) => e.name.contains(_searchText.value)).toList();
  }

  // Programs and scripts are not started from here: "Open" shows them in
  // the folder instead.
  static const _funtiRunnable = {
    'exe', 'msi', 'msix', 'appx', 'bat', 'cmd', 'com', 'scr', 'pif', 'cpl', //
    'msc', 'ps1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'hta', 'lnk', //
    'url', 'reg', 'jar', 'sh', 'run', 'appimage', 'deb', 'command', 'app',
  };

  bool _funtiIsRunnable(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 &&
        _funtiRunnable.contains(name.substring(dot + 1).toLowerCase());
  }

  Future<String?> _funtiLocalDownloads({bool subfolder = false}) async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir == null) return null;
      if (!subfolder) return dir.path;
      final sub = Directory(PathUtil.join(dir.path, 'FuntiDesk', isWindows));
      sub.createSync(recursive: true);
      return sub.path;
    } catch (e) {
      debugPrint('Downloads folder: $e');
      return null;
    }
  }

  // Names that are already in the target folder are asked about once for
  // the whole batch: replace, keep both ("name (2).ext") or skip. Files
  // inside folders that are merged on "Replace" are replaced without asking.
  Future<void> _funtiSendChecked(FileController source, List<Entry> items,
      DirectoryData target) async {
    String norm(String n) => target.options.isWindows ? n.toLowerCase() : n;
    final taken = {for (final e in target.directory.entries) norm(e.name)};
    final clashes = items.where((e) => taken.contains(norm(e.name))).toList();
    String? choice;
    if (clashes.isNotEmpty) {
      choice = await _funtiAskConflict(clashes);
      if (choice == null) return;
    }
    final send = <Entry>[];
    final names = <String>[];
    for (final e in items) {
      var name = e.name;
      if (clashes.contains(e)) {
        if (choice == 'skip') continue;
        if (choice == 'both') {
          name = funtiFreeName(e.name, (n) => taken.contains(norm(n)));
        }
      }
      taken.add(norm(name));
      send.add(e);
      names.add(name);
    }
    if (send.isEmpty) return;
    await source.funtiSendPaths(send, target,
        names: names, overwrite: choice == 'replace');
  }

  Future<String?> _funtiAskConflict(List<Entry> clashes) {
    final title = clashes.length == 1
        ? translate('funti-ft-exists-one').replaceAll('{}', clashes.first.name)
        : translate('funti-ft-exists-many')
            .replaceAll('{}', '${clashes.length}');
    final names = clashes.take(5).map((e) => e.name).join('\n') +
        (clashes.length > 5 ? '\n…' : '');
    return _ffi.dialogManager.show<String?>((setState, close, context) {
      cancel() => close(null);
      return CustomAlertDialog(
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        contentBoxConstraints: BoxConstraints(minWidth: 440, maxWidth: 440),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (clashes.length > 1) Text(names).paddingOnly(bottom: 12),
            Text(translate('funti-ft-exists-hint'),
                style: TextStyle(fontSize: 13, color: MyTheme.darkGray)),
          ],
        ),
        actions: [
          dialogButton('Cancel', onPressed: cancel, isOutline: true),
          dialogButton('funti-ft-skip',
              onPressed: () => close('skip'), isOutline: true),
          dialogButton('funti-ft-replace',
              onPressed: () => close('replace'), isOutline: true),
          dialogButton('funti-ft-keep-both', onPressed: () => close('both')),
        ],
        onSubmit: () => close('both'),
        onCancel: cancel,
      );
    }, useAnimation: false);
  }

  // A file on this computer opens in its program. A remote one is downloaded
  // to Downloads\FuntiDesk under a free name first and opens when it is
  // there.
  Future<void> _funtiOpenFile(Entry entry) async {
    if (isWeb) return;
    if (isLocal) {
      if (_funtiIsRunnable(entry.name)) {
        _funtiShowInFolder(entry.path);
      } else if (!await launchUrl(Uri.file(entry.path))) {
        showToast(translate('funti-ft-open-file-failed'));
      }
      return;
    }
    final dir = await _funtiLocalDownloads(subfolder: true);
    if (dir == null) {
      showToast(translate('funti-ft-downloads-missing'));
      return;
    }
    final name = funtiFreeName(entry.name,
        (n) => File(PathUtil.join(dir, n, isWindows)).existsSync());
    final fileModel = _ffi.fileModel;
    final target = DirectoryData(FileDirectory()..path = dir,
        fileModel.localController.options.value);
    final ids = await fileModel.remoteController
        .funtiSendPaths([entry], target, names: [name]);
    final runnable = _funtiIsRunnable(name);
    fileModel.jobController.funtiOnDone[ids.first] = (job) async {
      if (runnable) {
        _funtiShowInFolder(job.to);
      } else if (!await launchUrl(Uri.file(job.to))) {
        showToast(translate('funti-ft-open-file-failed'));
      }
    };
    showToast(translate(runnable ? 'funti-ft-downloading' : 'funti-ft-opening')
        .replaceAll('{}', entry.name));
  }

  // "To the Desktop / Downloads" of the other computer, without opening
  // the folder there first.
  Future<void> _funtiQuickSend(String folder) async {
    final items = _funtiSelection;
    if (items.isEmpty || isWeb) return;
    final fileModel = _ffi.fileModel;
    final DirectoryData target;
    if (isLocal) {
      final remote = fileModel.remoteController.options.value;
      if (remote.home.isEmpty) return;
      final path = PathUtil.join(remote.home, folder, remote.isWindows);
      try {
        final fd = await fileModel.fileFetcher
            .fetchDirectory(path, false, remote.showHidden);
        if (fd.path.isEmpty) fd.path = path;
        target = DirectoryData(fd, remote);
      } catch (e) {
        showToast(translate('funti-ft-folder-missing').replaceAll('{}', path));
        return;
      }
    } else {
      final dir = await _funtiLocalDownloads();
      if (dir == null) {
        showToast(translate('funti-ft-downloads-missing'));
        return;
      }
      target = DirectoryData(FileDirectory()..path = dir,
          fileModel.localController.options.value);
    }
    selectedItems.clear();
    await _funtiSendChecked(controller, items, target);
  }

  void _funtiCopyPath() {
    final items = _funtiSelection;
    final paths = items.isEmpty
        ? [controller.directory.value.path]
        : items.map((e) => e.path).toList();
    if (paths.first.isEmpty) return;
    Clipboard.setData(ClipboardData(text: paths.join('\n')));
    showToast(translate('funti-ft-path-copied'));
  }

  // Size of the selection; folders are read with everything inside.
  Future<void> _funtiShowSize() async {
    final items = _funtiSelection;
    if (items.isEmpty) return;
    final dm = _ffi.dialogManager;
    var cancelled = false;
    final tag = dm.showLoading(translate('funti-ft-size-counting'),
        onCancel: () => cancelled = true);
    var size = 0;
    var files = 0;
    try {
      for (final item in items) {
        if (cancelled) return;
        if (item.isFile) {
          size += item.size;
          files++;
          continue;
        }
        final fd = await _ffi.fileModel.fileFetcher
            .fetchDirectoryRecursiveToRemove(JobController.jobID.next(),
                item.path, isLocal, controller.options.value.showHidden,
                timeout: const Duration(seconds: 60));
        for (final e in fd.entries) {
          if (!e.isFile) continue;
          size += e.size;
          files++;
        }
      }
    } catch (e) {
      dm.dismissByTag(tag);
      if (!cancelled) showToast(translate('funti-ft-size-failed'));
      return;
    }
    dm.dismissByTag(tag);
    if (cancelled) return;
    final name = items.length == 1
        ? items.first.name
        : translate('funti-ft-selected').replaceAll('{}', '${items.length}');
    dm.show((setState, close, context) {
      return CustomAlertDialog(
        title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Text(translate('funti-ft-size-result')
            .replaceAll('{size}', readableFileSize(size.toDouble()))
            .replaceAll('{files}', '$files')),
        actions: [dialogButton('OK', onPressed: close)],
        onSubmit: close,
        onCancel: close,
      );
    });
  }

  // "25 items · Selected: 3, 12.4 MB" under the list.
  Widget _funtiStatusBar() {
    return Obx(() {
      final total = controller.directory.value.entries.length;
      final sel = selectedItems.items;
      var text = translate('funti-ft-items').replaceAll('{}', '$total');
      if (sel.isNotEmpty) {
        final files = sel.where((e) => e.isFile).toList();
        final selected =
            translate('funti-ft-selected').replaceAll('{}', '${sel.length}');
        text += ' · $selected';
        if (files.isNotEmpty) {
          final size = files.fold<int>(0, (s, e) => s + e.size);
          text += ', ${readableFileSize(size.toDouble())}';
          if (files.length < sel.length) {
            text += ' ${translate('funti-ft-without-folders')}';
          }
        }
      }
      return Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: MyTheme.darkGray))
          .paddingOnly(left: 4, top: 6);
    });
  }

  void _funtiCopy() {
    final items = _funtiSelection;
    if (items.isEmpty) return;
    final fileModel = _ffi.fileModel;
    fileModel.funtiCopied = items;
    fileModel.funtiCopiedFromLocal = isLocal;
    showToast(translate(
            isLocal ? 'funti-ft-copied-to-remote' : 'funti-ft-copied-to-local')
        .replaceAll('{}', '${items.length}'));
  }

  // Files copied on the other panel go to the folder open here. Copying
  // within one computer is not in the protocol.
  Future<void> _funtiPaste() async {
    final fileModel = _ffi.fileModel;
    final copied = fileModel.funtiCopied;
    final fromOtherSide =
        copied.isNotEmpty && fileModel.funtiCopiedFromLocal != isLocal;
    if (!fromOtherSide) {
      final sameSide = copied.isNotEmpty;
      if (!isLocal) {
        return _funtiPasteFromClipboard(
            emptyHint: sameSide ? 'funti-ft-copy-same-side' : null);
      }
      showToast(translate(
          sameSide ? 'funti-ft-copy-same-side' : 'funti-ft-paste-local-empty'));
      return;
    }
    final target = controller.directoryData();
    if (!_funtiFolderOpen(target)) {
      showToast(translate(isLocal
          ? 'funti-ft-paste-open-local-folder'
          : 'funti-ft-paste-open-folder'));
      return;
    }
    fileModel.funtiCopied = [];
    final source =
        isLocal ? fileModel.remoteController : fileModel.localController;
    await _funtiSendChecked(source, copied, target);
  }

  void _funtiRename() {
    final items = _funtiSelection;
    if (items.length != 1) return;
    controller.renameAction(items.first, isLocal);
  }

  Future<void> _funtiDelete() async {
    final items = _funtiSelection;
    if (items.isEmpty) return;
    if (await _funtiConfirmDelete(items) != true) return;
    final selection = SelectedItems(isLocal: isLocal)..items.addAll(items);
    selectedItems.clear();
    await controller.removeAction(selection, funtiConfirmed: true);
  }

  // One question for everything selected, instead of one per file.
  Future<bool?> _funtiConfirmDelete(List<Entry> items) {
    final title = items.length == 1
        ? translate('funti-ft-delete-one').replaceAll('{}', items.first.name)
        : translate('funti-ft-delete-many').replaceAll('{}', '${items.length}');
    final names = items.take(5).map((e) => e.name).join('\n') +
        (items.length > 5 ? '\n…' : '');
    return _ffi.dialogManager.show<bool>((setState, close, context) {
      cancel() => close(false);
      submit() => close(true);
      return CustomAlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_rounded, color: Colors.red),
            Expanded(
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis)
                  .paddingOnly(left: 10),
            ),
          ],
        ),
        contentBoxConstraints: BoxConstraints(minWidth: 400, maxWidth: 400),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (items.length > 1) Text(names).paddingOnly(bottom: 16),
            Text(
              translate('funti-ft-delete-note'),
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ),
        actions: [
          dialogButton("Cancel",
              icon: Icon(Icons.close_rounded),
              onPressed: cancel,
              isOutline: true),
          dialogButton("Delete",
              icon: Icon(Icons.delete_outline_rounded), onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    }, useAnimation: false);
  }

  mod_menu.PopupMenuEntry<void> _funtiMenuItem(
      String label, void Function()? onTap,
      {String hint = ''}) {
    return mod_menu.PopupMenuItem<void>(
      height: CustomPopupMenuTheme.height,
      enabled: onTap != null,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 200),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(translate(label)),
            if (hint.isNotEmpty)
              Text(hint,
                      style: TextStyle(fontSize: 12, color: MyTheme.darkGray))
                  .paddingOnly(left: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _funtiShowMenu(
      Offset at, List<mod_menu.PopupMenuEntry<void>> items) async {
    if (items.isEmpty) return;
    await mod_menu.showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: items,
      elevation: 8,
    );
  }

  // Right click on a file or folder: it becomes the selection unless it is
  // already in it, as in Explorer.
  Future<void> _funtiShowEntryMenu(
      Entry entry, Offset at, Rx<Entry?> rightClickEntry) async {
    if (!entry.isDrive && !selectedItems.items.contains(entry)) {
      selectedItems.clear();
      selectedItems.add(entry);
      setState(() {});
    }
    final items = _funtiSelection;
    final menu = <mod_menu.PopupMenuEntry<void>>[
      if (!entry.isFile)
        _funtiMenuItem('funti-ft-open', () {
          selectedItems.clear();
          controller.openDirectory(entry.path);
        })
      else if (!isWeb)
        _funtiMenuItem('funti-ft-open', () => _funtiOpenFile(entry),
            hint: 'Enter'),
      if (items.isNotEmpty && !isWeb) ...[
        _funtiMenuItem(isLocal ? 'funti-ft-send' : 'funti-ft-receive', () {
          selectedItems.clear();
          _funtiSendChecked(
              controller, items, controller.getOtherSideDirectoryData());
        }),
        if (isLocal) ...[
          _funtiMenuItem(
              'funti-ft-send-desktop', () => _funtiQuickSend('Desktop')),
          _funtiMenuItem(
              'funti-ft-send-downloads', () => _funtiQuickSend('Downloads')),
        ] else
          _funtiMenuItem(
              'funti-ft-receive-downloads', () => _funtiQuickSend('')),
        _funtiMenuItem('funti-ft-copy', _funtiCopy, hint: '${_funtiCmd}C'),
      ],
      if (items.isNotEmpty) ...[
        _funtiMenuItem('funti-ft-copy-path', _funtiCopyPath,
            hint: '${_funtiCmd}Shift+C'),
        _funtiMenuItem('funti-ft-size', _funtiShowSize),
      ],
      if (items.isNotEmpty) ...[
        const mod_menu.PopupMenuDivider(),
        _funtiMenuItem('Rename', items.length == 1 ? _funtiRename : null,
            hint: 'F2'),
        _funtiMenuItem('Delete', _funtiDelete, hint: 'Del'),
      ],
    ];
    rightClickEntry.value = entry;
    await _funtiShowMenu(at, menu);
    rightClickEntry.value = null;
  }

  // Right click on the empty part of the list.
  Future<void> _funtiShowFolderMenu(Offset at) async {
    await _funtiShowMenu(at, [
      if (!isWeb)
        _funtiMenuItem('funti-ft-paste-here', _funtiPaste,
            hint: '${_funtiCmd}V'),
      _funtiMenuItem('Create Folder', _funtiCreateFolder),
      _funtiMenuItem('funti-ft-refresh', () => controller.refresh(),
          hint: 'F5'),
      _funtiMenuItem('funti-ft-copy-path', _funtiCopyPath),
      _funtiMenuItem(
          'Select All',
          () => setState(() => selectedItems.selectAll(_funtiVisible)),
          hint: '${_funtiCmd}A'),
    ]);
  }

  void _funtiCreateFolder() {
    final name = TextEditingController();
    String? errorText;
    _ffi.dialogManager.show((setState, close, context) {
      name.addListener(() {
        if (errorText != null) {
          setState(() {
            errorText = null;
          });
        }
      });
      submit() {
        if (name.value.text.isNotEmpty) {
          if (!PathUtil.validName(
              name.value.text, controller.options.value.isWindows)) {
            setState(() {
              errorText = translate("Invalid folder name");
            });
            return;
          }
          controller.createDir(PathUtil.join(
            controller.directory.value.path,
            name.value.text,
            controller.options.value.isWindows,
          ));
          close();
        }
      }

      cancel() => close(false);
      return CustomAlertDialog(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset("assets/folder_new.svg",
                colorFilter: svgColor(MyTheme.accent)),
            Text(
              translate("Create Folder"),
            ).paddingOnly(
              left: 10,
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              decoration: InputDecoration(
                labelText: translate(
                  "Please enter the folder name",
                ),
                errorText: errorText,
              ),
              controller: name,
              autofocus: true,
            ).workaroundFreezeLinuxMint(),
          ],
        ),
        actions: [
          dialogButton(
            "Cancel",
            icon: Icon(Icons.close_rounded),
            onPressed: cancel,
            isOutline: true,
          ),
          dialogButton(
            "Ok",
            icon: Icon(Icons.done_rounded),
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    });
  }

  Future<void> _funtiPasteFromClipboard({String? emptyHint}) async {
    final fileModel = _ffi.fileModel;
    final remote = fileModel.remoteController.directoryData();
    // On Windows, "/" is the list of drives, not a folder.
    final path = remote.directory.path;
    if (path.isEmpty || (remote.options.isWindows && path == '/')) {
      showToast(translate('funti-ft-paste-open-folder'));
      return;
    }
    final items = <Entry>[];
    for (final file in await bind.mainFuntiClipboardFiles()) {
      final isDir = FileSystemEntity.isDirectorySync(file);
      if (!isDir && !File(file).existsSync()) continue;
      final name = file
          .split(Platform.pathSeparator)
          .lastWhere((e) => e.isNotEmpty, orElse: () => '');
      if (name.isEmpty) continue;
      items.add(Entry()
        ..entryType = isDir ? 0 : 4
        ..path = file
        ..name = name
        ..size = isDir ? 0 : File(file).lengthSync());
    }
    if (items.isEmpty) {
      showToast(translate(emptyHint ?? 'funti-ft-paste-empty'));
      return;
    }
    await _funtiSendChecked(fileModel.localController, items, remote);
  }

  void onLocationFocusChanged() {
    debugPrint("focus changed on local");
    if (_locationNode.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatus.value != LocationStatus.fileSearchBar) {
        _locationStatus.value = LocationStatus.bread;
      }
    }
  }

  Widget headTools() {
    var uploadButtonTapPosition = RelativeRect.fill;
    RxBool isUploadFolder =
        (bind.mainGetLocalOption(key: 'upload-folder-button') == 'Y').obs;
    return Container(
      child: Column(
        children: [
          // symbols
          PreferredSize(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                            color: MyTheme.accent,
                          ),
                          padding: EdgeInsets.all(8.0),
                          child: FutureBuilder<String>(
                              future: bind.sessionGetPlatform(
                                  sessionId: _ffi.sessionId,
                                  isRemote: !isLocal),
                              builder: (context, snapshot) {
                                if (snapshot.hasData &&
                                    snapshot.data!.isNotEmpty) {
                                  return getPlatformImage('${snapshot.data}');
                                } else {
                                  return CircularProgressIndicator(
                                    color: Theme.of(context)
                                        .tabBarTheme
                                        .labelColor,
                                  );
                                }
                              })),
                      Text(isLocal
                              ? translate("Local Computer")
                              : translate("Remote Computer"))
                          .marginOnly(left: 8.0)
                    ],
                  ),
                  preferredSize: Size(double.infinity, 70))
              .paddingOnly(bottom: 15),
          // buttons
          Row(
            children: [
              Row(
                children: [
                  MenuButton(
                    tooltip: translate('Back'),
                    padding: EdgeInsets.only(
                      right: 3,
                    ),
                    child: RotatedBox(
                      quarterTurns: 2,
                      child: SvgPicture.asset(
                        "assets/arrow.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                    ),
                    color: Theme.of(context).cardColor,
                    hoverColor: Theme.of(context).hoverColor,
                    onPressed: () {
                      selectedItems.clear();
                      controller.goBack();
                    },
                  ),
                  MenuButton(
                    tooltip: translate('Parent directory'),
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SvgPicture.asset(
                        "assets/arrow.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                    ),
                    color: Theme.of(context).cardColor,
                    hoverColor: Theme.of(context).hoverColor,
                    onPressed: () {
                      selectedItems.clear();
                      controller.goToParentDirectory();
                    },
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.all(
                        Radius.circular(8.0),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 2.5),
                      child: GestureDetector(
                        onTap: () {
                          _locationStatus.value =
                              _locationStatus.value == LocationStatus.bread
                                  ? LocationStatus.pathLocation
                                  : LocationStatus.bread;
                          Future.delayed(Duration.zero, () {
                            if (_locationStatus.value ==
                                LocationStatus.pathLocation) {
                              _locationNode.requestFocus();
                            }
                          });
                        },
                        child: Obx(
                          () => Container(
                            child: Row(
                              children: [
                                Expanded(
                                    child: _locationStatus.value ==
                                            LocationStatus.bread
                                        ? buildBread()
                                        : buildPathLocation()),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Obx(() {
                switch (_locationStatus.value) {
                  case LocationStatus.bread:
                    return MenuButton(
                      tooltip: translate('Search'),
                      onPressed: () {
                        _locationStatus.value = LocationStatus.fileSearchBar;
                        Future.delayed(
                            Duration.zero, () => _locationNode.requestFocus());
                      },
                      child: SvgPicture.asset(
                        "assets/search.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                  case LocationStatus.pathLocation:
                    return MenuButton(
                      onPressed: null,
                      child: SvgPicture.asset(
                        "assets/close.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).disabledColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                  case LocationStatus.fileSearchBar:
                    return MenuButton(
                      tooltip: translate('Clear'),
                      onPressed: () {
                        onSearchText("", isLocal);
                        _locationStatus.value = LocationStatus.bread;
                      },
                      child: SvgPicture.asset(
                        "assets/close.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                }
              }),
              MenuButton(
                tooltip: translate('Refresh File'),
                padding: EdgeInsets.only(
                  left: 3,
                ),
                onPressed: () {
                  controller.refresh();
                },
                child: SvgPicture.asset(
                  "assets/refresh.svg",
                  colorFilter:
                      svgColor(Theme.of(context).tabBarTheme.labelColor),
                ),
                color: Theme.of(context).cardColor,
                hoverColor: Theme.of(context).hoverColor,
              ),
            ],
          ),
          Row(
            textDirection: isLocal ? TextDirection.ltr : TextDirection.rtl,
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment:
                      isLocal ? MainAxisAlignment.start : MainAxisAlignment.end,
                  children: [
                    MenuButton(
                      tooltip: translate('Home'),
                      padding: EdgeInsets.only(
                        right: 3,
                      ),
                      onPressed: () {
                        controller.goToHomeDirectory();
                      },
                      child: SvgPicture.asset(
                        "assets/home.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    ),
                    MenuButton(
                      tooltip: translate('Create Folder'),
                      onPressed: _funtiCreateFolder,
                      child: SvgPicture.asset(
                        "assets/folder_new.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    ),
                    Obx(() => MenuButton(
                          tooltip: translate('Delete'),
                          onPressed: SelectedItems.valid(selectedItems.items)
                              ? _funtiDelete
                              : null,
                          child: SvgPicture.asset(
                            "assets/trash.svg",
                            colorFilter: svgColor(
                                Theme.of(context).tabBarTheme.labelColor),
                          ),
                          color: Theme.of(context).cardColor,
                          hoverColor: Theme.of(context).hoverColor,
                        )),
                    menu(isLocal: isLocal),
                    if (!isWeb)
                      Obx(() => MenuButton(
                            tooltip: translate(_funtiThumbs.value
                                ? 'funti-ft-thumbs-off'
                                : 'funti-ft-thumbs-on'),
                            onPressed: _funtiToggleThumbs,
                            child: Icon(
                                _funtiThumbs.value
                                    ? Icons.view_list_rounded
                                    : Icons.photo_library_outlined,
                                color: Theme.of(context)
                                    .tabBarTheme
                                    .labelColor),
                            color: Theme.of(context).cardColor,
                            hoverColor: Theme.of(context).hoverColor,
                          )),
                    if (!isLocal && !isWeb)
                      MenuButton(
                        tooltip: translate('funti-ft-paste'),
                        onPressed: _funtiPasteFromClipboard,
                        child: Icon(Icons.content_paste_rounded,
                            color: Theme.of(context).tabBarTheme.labelColor),
                        color: Theme.of(context).cardColor,
                        hoverColor: Theme.of(context).hoverColor,
                      ),
                  ],
                ),
              ),
              if (isWeb)
                Obx(() => ElevatedButton.icon(
                      style: ButtonStyle(
                        padding: MaterialStateProperty.all<EdgeInsetsGeometry>(
                            isLocal
                                ? EdgeInsets.only(left: 10)
                                : EdgeInsets.only(right: 10)),
                        backgroundColor: MaterialStateProperty.all(
                          selectedItems.items.isEmpty
                              ? MyTheme.accent80
                              : MyTheme.accent,
                        ),
                      ),
                      onPressed: () =>
                          {webselectFiles(is_folder: isUploadFolder.value)},
                      label: InkWell(
                        hoverColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        focusColor: Colors.transparent,
                        onTapDown: (e) {
                          final x = e.globalPosition.dx;
                          final y = e.globalPosition.dy;
                          uploadButtonTapPosition =
                              RelativeRect.fromLTRB(x, y, x, y);
                        },
                        onTap: () async {
                          final value = await showMenu<bool>(
                              context: context,
                              position: uploadButtonTapPosition,
                              items: [
                                PopupMenuItem<bool>(
                                  value: false,
                                  child: Text(translate('Upload files')),
                                ),
                                PopupMenuItem<bool>(
                                  value: true,
                                  child: Text(translate('Upload folder')),
                                ),
                              ]);
                          if (value != null) {
                            isUploadFolder.value = value;
                            bind.mainSetLocalOption(
                                key: 'upload-folder-button',
                                value: value ? 'Y' : '');
                            webselectFiles(is_folder: value);
                          }
                        },
                        child: Icon(Icons.arrow_drop_down),
                      ),
                      icon: Text(
                        translate(isUploadFolder.isTrue
                            ? 'Upload folder'
                            : 'Upload files'),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.white,
                        ),
                      ).marginOnly(left: 8),
                    )).marginOnly(left: 16),
              Obx(() => ElevatedButton.icon(
                    style: ButtonStyle(
                      padding: MaterialStateProperty.all<EdgeInsetsGeometry>(
                          isLocal
                              ? EdgeInsets.only(left: 10)
                              : EdgeInsets.only(right: 10)),
                      backgroundColor: MaterialStateProperty.all(
                        selectedItems.items.isEmpty
                            ? MyTheme.accent80
                            : MyTheme.accent,
                      ),
                    ),
                    onPressed: SelectedItems.valid(selectedItems.items)
                        ? () {
                            final otherSideData =
                                controller.getOtherSideDirectoryData();
                            if (isWeb) {
                              controller.sendFiles(
                                  selectedItems, otherSideData);
                            } else {
                              _funtiSendChecked(controller,
                                  selectedItems.items.toList(), otherSideData);
                            }
                            selectedItems.clear();
                          }
                        : null,
                    icon: isLocal
                        ? Text(
                            translate('Send'),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: selectedItems.items.isEmpty
                                  ? Theme.of(context).brightness ==
                                          Brightness.light
                                      ? MyTheme.grayBg
                                      : MyTheme.darkGray
                                  : Colors.white,
                            ),
                          )
                        : isWeb
                            ? Offstage()
                            : RotatedBox(
                                quarterTurns: 2,
                                child: SvgPicture.asset(
                                  "assets/arrow.svg",
                                  colorFilter: svgColor(
                                      selectedItems.items.isEmpty
                                          ? Theme.of(context).brightness ==
                                                  Brightness.light
                                              ? MyTheme.grayBg
                                              : MyTheme.darkGray
                                          : Colors.white),
                                  alignment: Alignment.bottomRight,
                                ),
                              ),
                    label: isLocal
                        ? SvgPicture.asset(
                            "assets/arrow.svg",
                            colorFilter: svgColor(selectedItems.items.isEmpty
                                ? Theme.of(context).brightness ==
                                        Brightness.light
                                    ? MyTheme.grayBg
                                    : MyTheme.darkGray
                                : Colors.white),
                          )
                        : Text(
                            translate(isWeb ? 'Download' : 'Receive'),
                            style: TextStyle(
                              color: selectedItems.items.isEmpty
                                  ? Theme.of(context).brightness ==
                                          Brightness.light
                                      ? MyTheme.grayBg
                                      : MyTheme.darkGray
                                  : Colors.white,
                            ),
                          ),
                  )),
            ],
          ).marginOnly(top: 8.0)
        ],
      ),
    );
  }

  Widget menu({bool isLocal = false}) {
    var menuPos = RelativeRect.fill;

    final List<MenuEntryBase<String>> items = [
      MenuEntrySwitch<String>(
        switchType: SwitchType.scheckbox,
        text: translate("Show Hidden Files"),
        getter: () async {
          return controller.options.value.showHidden;
        },
        setter: (bool v) async {
          controller.toggleShowHidden();
        },
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
          childBuilder: (style) => Text(translate("Select All"), style: style),
          proc: () => setState(() =>
              selectedItems.selectAll(controller.directory.value.entries)),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true),
      MenuEntryButton(
          childBuilder: (style) =>
              Text(translate("Unselect All"), style: style),
          proc: () => selectedItems.clear(),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true)
    ];

    return Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      child: MenuButton(
        tooltip: translate('More'),
        onPressed: () => mod_menu.showMenu(
          context: context,
          position: menuPos,
          items: items
              .map(
                (e) => e.build(
                  context,
                  MenuConfig(
                      commonColor: CustomPopupMenuTheme.commonColor,
                      height: CustomPopupMenuTheme.height,
                      dividerHeight: CustomPopupMenuTheme.dividerHeight),
                ),
              )
              .expand((i) => i)
              .toList(),
          elevation: 8,
        ),
        child: SvgPicture.asset(
          "assets/dots.svg",
          colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
        ),
        color: Theme.of(context).cardColor,
        hoverColor: Theme.of(context).hoverColor,
      ),
    );
  }

  Widget _buildFileList(
      BuildContext context, ScrollController scrollController) {
    final fd = controller.directory.value;
    final entries = fd.entries;
    Rx<Entry?> rightClickEntry = Rx(null);

    return ListSearchActionListener(
      node: _keyboardNode,
      buffer: _listSearchBuffer,
      onNext: (buffer) {
        debugPrint("searching next for $buffer");
        assert(buffer.length == 1);
        assert(selectedItems.items.length <= 1);
        var skipCount = 0;
        if (selectedItems.items.isNotEmpty) {
          final index = entries.indexOf(selectedItems.items.first);
          if (index < 0) {
            return;
          }
          skipCount = index + 1;
        }
        var searchResult = entries
            .skip(skipCount)
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        if (searchResult.isEmpty) {
          // cannot find next, lets restart search from head
          debugPrint("restart search from head");
          searchResult = entries.where(
              (element) => element.name.toLowerCase().startsWith(buffer));
        }
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            _funtiRowHeight);
      },
      onSearch: (buffer) {
        debugPrint("searching for $buffer");
        final selectedEntries = selectedItems;
        final searchResult = entries
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        selectedEntries.clear();
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            _funtiRowHeight);
      },
      child: Obx(() {
        final entries = controller.directory.value.entries;
        final filteredEntries = _searchText.isNotEmpty
            ? entries.where((element) {
                return element.name.contains(_searchText.value);
              }).toList(growable: false)
            : entries;
        // Keep rows lazy so large directories only build visible list items.
        final rows = filteredEntries.map((entry) {
          final sizeStr =
              entry.isFile ? readableFileSize(entry.size.toDouble()) : "";
          final lastModifiedStr = entry.isDrive
              ? " "
              : "${entry.lastModified().toString().replaceAll(".000", "")}   ";
          var secondaryPosition = Offset.zero;
          onTap() {
            _keyboardNode.requestFocus();
            final items = selectedItems;
            // handle double click
            if (_checkDoubleClick(entry)) {
              items.clear();
              if (entry.isFile) {
                _funtiOpenFile(entry);
              } else {
                controller.openDirectory(entry.path);
              }
              return;
            }
            _onSelectedChanged(items, filteredEntries, entry, isLocal);
          }

          onSecondaryTap() {
            _funtiShowEntryMenu(entry, secondaryPosition, rightClickEntry);
          }

          onSecondaryTapDown(TapDownDetails details) {
            secondaryPosition = details.globalPosition;
          }

          return Padding(
            padding: EdgeInsets.symmetric(vertical: 1),
            child: Obx(() => Container(
                decoration: BoxDecoration(
                  color: selectedItems.items.contains(entry)
                      ? MyTheme.button
                      : Theme.of(context).cardColor,
                  borderRadius: BorderRadius.all(
                    Radius.circular(5.0),
                  ),
                  border: rightClickEntry.value == entry
                      ? Border.all(
                          color: MyTheme.button,
                          width: 1.0,
                        )
                      : null,
                ),
                key: ValueKey(entry.name),
                height: _funtiRowHeight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Expanded(
                      child: InkWell(
                        child: Row(
                          children: [
                            GestureDetector(
                              child: Obx(
                                () => Container(
                                    width: _nameColWidth.value,
                                    child: Tooltip(
                                      waitDuration: Duration(milliseconds: 500),
                                      message: entry.name,
                                      child: Row(children: [
                                        entry.isDrive
                                            ? Image(
                                                    image: iconHardDrive,
                                                    fit: BoxFit.scaleDown,
                                                    color: Theme.of(context)
                                                        .iconTheme
                                                        .color
                                                        ?.withOpacity(0.7))
                                                .paddingAll(4)
                                            : _funtiIcon(entry),
                                        Expanded(
                                            child: Text(entry.name.nonBreaking,
                                                style: TextStyle(
                                                    color: selectedItems.items
                                                            .contains(entry)
                                                        ? Colors.white
                                                        : null),
                                                overflow:
                                                    TextOverflow.ellipsis))
                                      ]),
                                    )),
                              ),
                              onTap: onTap,
                              onSecondaryTap: onSecondaryTap,
                              onSecondaryTapDown: onSecondaryTapDown,
                            ),
                            SizedBox(
                              width: 2.0,
                            ),
                            GestureDetector(
                              child: Obx(
                                () => SizedBox(
                                  width: _modifiedColWidth.value,
                                  child: Tooltip(
                                      waitDuration: Duration(milliseconds: 500),
                                      message: lastModifiedStr,
                                      child: Text(
                                        lastModifiedStr,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: selectedItems.items
                                                  .contains(entry)
                                              ? Colors.white70
                                              : MyTheme.darkGray,
                                        ),
                                      )),
                                ),
                              ),
                              onTap: onTap,
                              onSecondaryTap: onSecondaryTap,
                              onSecondaryTapDown: onSecondaryTapDown,
                            ),
                            // Divider from header.
                            SizedBox(
                              width: 2.0,
                            ),
                            Expanded(
                              // width: 100,
                              child: GestureDetector(
                                child: Tooltip(
                                  waitDuration: Duration(milliseconds: 500),
                                  message: sizeStr,
                                  child: Text(
                                    sizeStr,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color:
                                            selectedItems.items.contains(entry)
                                                ? Colors.white70
                                                : MyTheme.darkGray),
                                  ),
                                ),
                                onTap: onTap,
                                onSecondaryTap: onSecondaryTap,
                                onSecondaryTapDown: onSecondaryTapDown,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ))),
          );
        });

        return Column(
          children: [
            // Header
            Row(
              children: [
                Expanded(child: _buildFileBrowserHeader(context)),
              ],
            ),
            // Body
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onSecondaryTapUp: (details) =>
                    _funtiShowFolderMenu(details.globalPosition),
                child: ListView.builder(
                  controller: scrollController,
                  itemExtent: _funtiRowHeight,
                  itemBuilder: (context, index) {
                    return rows.elementAt(index);
                  },
                  itemCount: rows.length,
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  onSearchText(String searchText, bool isLocal) {
    selectedItems.clear();
    _searchText.value = searchText;
  }

  void _jumpToEntry(bool isLocal, Entry entry,
      ScrollController scrollController, double rowHeight) {
    final entries = controller.directory.value.entries;
    final index = entries.indexOf(entry);
    if (index == -1) {
      debugPrint("entry is not valid: ${entry.path}");
    }
    final selectedEntries = selectedItems;
    final searchResult = entries.where((element) => element == entry);
    selectedEntries.clear();
    if (searchResult.isEmpty) {
      return;
    }
    final offset = min(
        max(scrollController.position.minScrollExtent,
            entries.indexOf(searchResult.first) * rowHeight),
        scrollController.position.maxScrollExtent);
    scrollController.jumpTo(offset);
    selectedEntries.add(searchResult.first);
    debugPrint("focused on ${searchResult.first.name}");
  }

  KeyEventResult _onFileListKeyEvent(FocusNode node, KeyEvent event) {
    // A focused child such as a sort header keeps its default keys, e.g.
    // Enter to sort.
    if (!_keyboardNode.hasPrimaryFocus) return KeyEventResult.ignored;
    for (final binding in _fileListKeyBindings().entries) {
      if (binding.key.accepts(event, HardwareKeyboard.instance)) {
        binding.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Map<ShortcutActivator, VoidCallback> _fileListKeyBindings() {
    int all() => controller.directory.value.entries.length;
    return {
      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
          _moveSelectionByKey(-1, false),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          _moveSelectionByKey(1, false),
      const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
          _moveSelectionByKey(-1, true),
      const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () =>
          _moveSelectionByKey(1, true),
      // Unhandled, they would move keyboard focus to the other pane.
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {},
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {},
      const SingleActivator(LogicalKeyboardKey.pageUp): () =>
          _moveSelectionByKey(_pageDelta(false), false),
      const SingleActivator(LogicalKeyboardKey.pageDown): () =>
          _moveSelectionByKey(_pageDelta(true), false),
      const SingleActivator(LogicalKeyboardKey.home): () =>
          _moveSelectionByKey(-all(), false),
      const SingleActivator(LogicalKeyboardKey.end): () =>
          _moveSelectionByKey(all(), false),
      const SingleActivator(LogicalKeyboardKey.pageUp, shift: true): () =>
          _moveSelectionByKey(_pageDelta(false), true),
      const SingleActivator(LogicalKeyboardKey.pageDown, shift: true): () =>
          _moveSelectionByKey(_pageDelta(true), true),
      const SingleActivator(LogicalKeyboardKey.home, shift: true): () =>
          _moveSelectionByKey(-all(), true),
      const SingleActivator(LogicalKeyboardKey.end, shift: true): () =>
          _moveSelectionByKey(all(), true),
      const SingleActivator(LogicalKeyboardKey.enter): _openSelectedDirectory,
      const SingleActivator(LogicalKeyboardKey.numpadEnter):
          _openSelectedDirectory,
    };
  }

  void _openSelectedDirectory() {
    final items = selectedItems.items;
    // FUNTIDESK: Enter on a file opens it.
    if (items.length == 1 && items.first.isFile) {
      _funtiOpenFile(items.first);
      return;
    }
    if (items.length != 1 || items.first.isFile) return;
    controller.openDirectory(items.first.path);
    selectedItems.clear();
  }

  List<Entry> _filteredEntries() {
    final entries = controller.directory.value.entries;
    return _searchText.isNotEmpty
        ? entries.where((element) {
            return element.name.contains(_searchText.value);
          }).toList(growable: false)
        : entries;
  }

  int _pageDelta(bool down) {
    final entries = _filteredEntries();
    final items = selectedItems.items;
    final index = items.isEmpty ? -1 : entries.indexOf(items.last);
    final position = _fileListScrollController.position;
    final first = (position.pixels / _funtiRowHeight).ceil();
    final last = ((position.pixels + position.viewportDimension) /
                _funtiRowHeight)
            .floor() -
        1;
    return pageDelta(
        index >= 0 ? index : (down ? -1 : entries.length), first, last, down);
  }

  void _moveSelectionByKey(int delta, bool extend) {
    final filteredEntries = _filteredEntries();
    final selection =
        navigateSelection(filteredEntries, selectedItems.items, delta, extend);
    if (selection.isEmpty) return;
    selectedItems.items.assignAll(selection.where((e) => !e.isDrive));
    final position = _fileListScrollController.position;
    final top =
        filteredEntries.indexOf(selection.last) * _funtiRowHeight;
    final bottom = top + _funtiRowHeight;
    if (top < position.pixels) {
      _fileListScrollController.jumpTo(top);
    } else if (bottom > position.pixels + position.viewportDimension) {
      _fileListScrollController.jumpTo(bottom - position.viewportDimension);
    }
  }

  void _onSelectedChanged(SelectedItems selectedItems, List<Entry> entries,
      Entry entry, bool isLocal) {
    final isCtrlDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlRight);
    final isShiftDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftRight);
    if (isCtrlDown) {
      if (selectedItems.items.contains(entry)) {
        selectedItems.remove(entry);
      } else {
        selectedItems.add(entry);
      }
    } else if (isShiftDown) {
      final List<int> indexGroup = [];
      for (var selected in selectedItems.items) {
        indexGroup.add(entries.indexOf(selected));
      }
      indexGroup.add(entries.indexOf(entry));
      indexGroup.removeWhere((e) => e == -1);
      final maxIndex = indexGroup.reduce(max);
      final minIndex = indexGroup.reduce(min);
      selectedItems.clear();
      entries
          .getRange(minIndex, maxIndex + 1)
          .forEach((e) => selectedItems.add(e));
    } else {
      selectedItems.clear();
      selectedItems.add(entry);
    }
    setState(() {});
  }

  bool _checkDoubleClick(Entry entry) {
    final current = DateTime.now().millisecondsSinceEpoch;
    final elapsed = current - _lastClickTime;
    _lastClickTime = current;
    if (_lastClickEntry == entry) {
      if (elapsed < bind.getDoubleClickTime()) {
        return true;
      }
    } else {
      _lastClickEntry = entry;
    }
    return false;
  }

  void _onDrag(double dx, RxDouble column1, RxDouble column2) {
    if (column1.value + dx <= _fileTransferMinimumWidth ||
        column2.value - dx <= _fileTransferMinimumWidth) {
      return;
    }
    column1.value += dx;
    column2.value -= dx;
    column1.value = max(_fileTransferMinimumWidth, column1.value);
    column2.value = max(_fileTransferMinimumWidth, column2.value);
  }

  Widget _buildFileBrowserHeader(BuildContext context) {
    final padding = EdgeInsets.all(1.0);
    return SizedBox(
      key: _globalHeaderKey,
      height: kDesktopFileTransferHeaderHeight,
      child: Row(
        children: [
          Obx(
            () => headerItemFunc(
                _nameColWidth.value, SortBy.name, translate("Name")),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) =>
                _onDrag(dx, _nameColWidth, _modifiedColWidth),
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(_modifiedColWidth.value, SortBy.modified,
                translate("Modified")),
          ),
          DraggableDivider(
              axis: Axis.vertical,
              onPointerMove: (dx) =>
                  _onDrag(dx, _modifiedColWidth, _sizeColWidth),
              padding: padding),
          Expanded(
              child: headerItemFunc(
                  _sizeColWidth.value, SortBy.size, translate("Size")))
        ],
      ),
    );
  }

  Widget headerItemFunc(double? width, SortBy sortBy, String name) {
    final headerTextStyle =
        Theme.of(context).dataTableTheme.headingTextStyle ?? TextStyle();
    return ObxValue<Rx<bool?>>(
        (ascending) => InkWell(
              onTap: () {
                if (ascending.value == null) {
                  ascending.value = true;
                } else {
                  ascending.value = !ascending.value!;
                }
                controller.changeSortStyle(sortBy,
                    isLocal: isLocal, ascending: ascending.value!);
              },
              child: SizedBox(
                width: width,
                height: kDesktopFileTransferHeaderHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: headerTextStyle,
                        overflow: TextOverflow.ellipsis,
                      ).marginOnly(left: 4),
                    ),
                    ascending.value != null
                        ? Icon(
                            ascending.value!
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                          )
                        : SizedBox()
                  ],
                ),
              ),
            ), () {
      if (controller.sortBy.value == sortBy) {
        return controller.sortAscending.obs;
      } else {
        return Rx<bool?>(null);
      }
    }());
  }

  Widget buildBread() {
    final items = getPathBreadCrumbItems(isLocal, (list) {
      var path = "";
      for (var item in list) {
        path = PathUtil.join(path, item, controller.options.value.isWindows);
      }
      controller.openDirectory(path);
    });

    return items.isEmpty
        ? Offstage()
        : Row(
            key: _locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
                Expanded(
                  child: Listener(
                    // handle mouse wheel
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        final sc = _breadCrumbScroller;
                        final scale = isWindows ? 2 : 4;
                        sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                      }
                    },
                    child: BreadCrumb(
                      items: items,
                      divider: const Icon(Icons.keyboard_arrow_right_rounded),
                      overflow: ScrollableOverflow(
                        controller: _breadCrumbScroller,
                      ),
                    ),
                  ),
                ),
                ActionIcon(
                  message: "",
                  icon: Icons.keyboard_arrow_down_rounded,
                  onTap: () async {
                    final renderBox = _locationBarKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    _locationBarKey.currentContext?.size;

                    final size = renderBox.size;
                    final offset = renderBox.localToGlobal(Offset.zero);

                    final x = offset.dx;
                    final y = offset.dy + size.height + 1;

                    final isPeerWindows = controller.options.value.isWindows;
                    final List<MenuEntryBase> menuItems = [
                      MenuEntryButton(
                          childBuilder: (TextStyle? style) => isPeerWindows
                              ? buildWindowsThisPC(context, style)
                              : Text(
                                  '/',
                                  style: style,
                                ),
                          proc: () {
                            controller.openDirectory('/');
                          },
                          dismissOnClicked: true),
                      MenuEntryDivider()
                    ];
                    if (isPeerWindows) {
                      var loadingTag = "";
                      if (!isLocal) {
                        loadingTag = _ffi.dialogManager.showLoading("Waiting");
                      }
                      try {
                        final showHidden = controller.options.value.showHidden;
                        final fd = await controller.fileFetcher
                            .fetchDirectory("/", isLocal, showHidden);
                        for (var entry in fd.entries) {
                          menuItems.add(MenuEntryButton(
                              childBuilder: (TextStyle? style) =>
                                  Row(children: [
                                    Image(
                                        image: iconHardDrive,
                                        fit: BoxFit.scaleDown,
                                        color: Theme.of(context)
                                            .iconTheme
                                            .color
                                            ?.withOpacity(0.7)),
                                    SizedBox(width: 10),
                                    Text(
                                      entry.name,
                                      style: style,
                                    )
                                  ]),
                              proc: () {
                                controller.openDirectory('${entry.name}\\');
                              },
                              dismissOnClicked: true));
                        }
                        menuItems.add(MenuEntryDivider());
                      } catch (e) {
                        debugPrint("buildBread fetchDirectory err=$e");
                      } finally {
                        if (!isLocal) {
                          _ffi.dialogManager.dismissByTag(loadingTag);
                        }
                      }
                    }
                    mod_menu.showMenu(
                        context: context,
                        position: RelativeRect.fromLTRB(x, y, x, y),
                        elevation: 4,
                        items: menuItems
                            .map((e) => e.build(
                                context,
                                MenuConfig(
                                    commonColor:
                                        CustomPopupMenuTheme.commonColor,
                                    height: CustomPopupMenuTheme.height,
                                    dividerHeight:
                                        CustomPopupMenuTheme.dividerHeight,
                                    boxWidth: size.width)))
                            .expand((i) => i)
                            .toList());
                  },
                  iconSize: 20,
                )
              ]);
  }

  List<BreadCrumbItem> getPathBreadCrumbItems(
      bool isLocal, void Function(List<String>) onPressed) {
    final path = controller.directory.value.path;
    final breadCrumbList = List<BreadCrumbItem>.empty(growable: true);
    final isWindows = controller.options.value.isWindows;
    if (isWindows && path == '/') {
      breadCrumbList.add(BreadCrumbItem(
          content: TextButton(
                  child: buildWindowsThisPC(context),
                  style: ButtonStyle(
                      minimumSize: MaterialStateProperty.all(Size(0, 0))),
                  onPressed: () => onPressed(['/']))
              .marginSymmetric(horizontal: 4)));
    } else {
      final list = PathUtil.split(path, isWindows);
      breadCrumbList.addAll(
        list.asMap().entries.map(
              (e) => BreadCrumbItem(
                content: TextButton(
                  child: Text(e.value),
                  style: ButtonStyle(
                    minimumSize: MaterialStateProperty.all(
                      Size(0, 0),
                    ),
                  ),
                  onPressed: () => onPressed(
                    list.sublist(0, e.key + 1),
                  ),
                ).marginSymmetric(horizontal: 4),
              ),
            ),
      );
    }
    return breadCrumbList;
  }

  breadCrumbScrollToEnd() {
    Future.delayed(Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
            _breadCrumbScroller.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.fastLinearToSlowEaseIn);
      }
    });
  }

  Widget buildPathLocation() {
    final text = _locationStatus.value == LocationStatus.pathLocation
        ? controller.directory.value.path
        : _searchText.value;
    final textController = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length);
    return Row(
      children: [
        SvgPicture.asset(
          _locationStatus.value == LocationStatus.pathLocation
              ? "assets/folder.svg"
              : "assets/search.svg",
          colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
        ),
        Expanded(
          child: TextField(
            focusNode: _locationNode,
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              prefix: Padding(
                padding: EdgeInsets.only(left: 4.0),
              ),
            ),
            controller: textController,
            onSubmitted: _locationStatus.value == LocationStatus.pathLocation
                ? _openTyped
                : null,
            onChanged: _locationStatus.value == LocationStatus.fileSearchBar
                ? (searchText) => onSearchText(searchText, isLocal)
                : null,
          ).workaroundFreezeLinuxMint(),
        )
      ],
    );
  }

  // openDirectory(String path, {bool isLocal = false}) {
  //   model.openDirectory(path, isLocal: isLocal);
  // }
}

/// Selection after a navigation key moves it by [delta] rows. A shift range is
/// returned ordered from its anchor to the moved end, so the first and last
/// items of [selected] stand for those two ends on the next press without
/// separate state.
@visibleForTesting
List<Entry> navigateSelection(
    List<Entry> entries, List<Entry> selected, int delta, bool extend) {
  if (entries.isEmpty) return [];
  final current = selected.isEmpty ? -1 : entries.indexOf(selected.last);
  // With nothing selected, moving down starts above the first row and moving
  // up below the last one, as the Sciter grid did.
  final lead = current >= 0 ? current : (delta > 0 ? -1 : entries.length);
  final next = (lead + delta).clamp(0, entries.length - 1);
  if (!extend || current < 0) return [entries[next]];
  final first = entries.indexOf(selected.first);
  final anchor = first < 0 ? current : first;
  final step = next < anchor ? -1 : 1;
  return [for (var i = anchor; i != next + step; i += step) entries[i]];
}

/// Rows a PageUp/PageDown press moves from [lead] while rows [first]..[last]
/// are fully visible: to that edge first, then a page further, as list views
/// do.
@visibleForTesting
int pageDelta(int lead, int first, int last, bool down) {
  final page = max(1, last - first);
  if (down) return lead < last ? last - lead : page;
  return lead > first ? first - lead : -page;
}

Widget buildWindowsThisPC(BuildContext context, [TextStyle? textStyle]) {
  final color = Theme.of(context).iconTheme.color?.withOpacity(0.7);
  return Row(children: [
    Icon(Icons.computer, size: 20, color: color),
    SizedBox(width: 10),
    Text(translate('This PC'), style: textStyle)
  ]);
}

// FUNTIDESK: "Show in folder" for a file on this computer.
void _funtiShowInFolder(String path) {
  if (isWeb || path.isEmpty) return;
  if (Platform.isWindows) {
    Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    Process.run('open', ['-R', path]);
  } else {
    launchUrl(Uri.directory(File(path).parent.path));
  }
}

// FUNTIDESK (ADR-017): the preview of a picture in the "Pictures" mode. A
// file on this computer is decoded here; a remote one is asked for.
class _FuntiThumb extends StatefulWidget {
  final Entry entry;
  final bool isLocal;
  final FuntiThumbnails thumbs;
  final Widget fallback;

  const _FuntiThumb(
      {super.key,
      required this.entry,
      required this.isLocal,
      required this.thumbs,
      required this.fallback});

  @override
  State<_FuntiThumb> createState() => _FuntiThumbState();
}

class _FuntiThumbState extends State<_FuntiThumb> {
  static const _side = 48.0;
  Future<Uint8List?>? _remote;

  @override
  void initState() {
    super.initState();
    if (!widget.isLocal) _remote = widget.thumbs.get(widget.entry);
  }

  @override
  void dispose() {
    if (!widget.isLocal) widget.thumbs.forget(widget.entry);
    super.dispose();
  }

  Widget _box(Widget image) => Container(
        width: _side,
        height: _side,
        margin: const EdgeInsets.only(right: 6),
        child: ClipRRect(borderRadius: BorderRadius.circular(4), child: image),
      );

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    if (widget.isLocal) {
      if (entry.size > funtiThumbMaxFileSize) return widget.fallback;
      return _box(Image.file(File(entry.path),
          cacheWidth: (_side * MediaQuery.of(context).devicePixelRatio).round(),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => widget.fallback));
    }
    return FutureBuilder<Uint8List?>(
        future: _remote,
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? widget.thumbs.cached(entry);
          if (bytes == null) return widget.fallback;
          return _box(Image.memory(bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => widget.fallback));
        });
  }
}
