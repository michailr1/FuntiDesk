// FUNTIDESK: main window content (handoff 2026-10-07, section 4).
//
// Banner with the scene, "This computer", "Connect", "My devices" and the
// status bar. Every value shown here comes from the running client: the
// rendezvous status, the real ID and one-time password, the permanent
// password settings, recent and favourite peers. Colours come only from
// FuntiTokens. Upstream models are reused unchanged.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/funti_theme.dart';
import '../../common/widgets/autocomplete.dart';
import '../../common/widgets/dialog.dart';
import '../../consts.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';
import '../../models/state_model.dart';
import '../widgets/funti_family.dart';
import '../widgets/funti_home_scene.dart';
import 'desktop_home_page.dart' show setPasswordDialog;

const String _kOptionHideBanner = 'funti-home-banner-hidden';

/// Whether the main-screen picture is hidden. Shared with the settings page,
/// which can bring the picture back after it was closed.
final ValueNotifier<bool> funtiHomeBannerHidden =
    ValueNotifier(bind.mainGetLocalOption(key: _kOptionHideBanner) == 'Y');

void setFuntiHomeBannerHidden(bool hidden) {
  bind.mainSetLocalOption(key: _kOptionHideBanner, value: hidden ? 'Y' : '');
  funtiHomeBannerHidden.value = hidden;
}

class FuntiHomeView extends StatefulWidget {
  const FuntiHomeView({
    Key? key,
    required this.notices,
    required this.showThisComputer,
  }) : super(key: key);

  /// Service, UAC, permission and preset-password notices of the upstream
  /// home page. They must stay visible: without them the portable build
  /// cannot be installed as a service.
  final Widget notices;
  final bool showThisComputer;

  @override
  State<FuntiHomeView> createState() => _FuntiHomeViewState();
}

class _FuntiHomeViewState extends State<FuntiHomeView> {
  Timer? _statusTimer;
  bool get _bannerHidden => funtiHomeBannerHidden.value;

  @override
  void initState() {
    super.initState();
    funtiHomeBannerHidden.addListener(_onBannerChanged);
    // The upstream status line is not shown here, so poll the same source.
    _statusTimer = periodic_immediate(const Duration(seconds: 1), () async {
      final status =
          jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
      final statusNum = status['status_num'] as int;
      stateGlobal.svcStatus.value = statusNum == 1
          ? SvcStatus.ready
          : statusNum == 0
              ? SvcStatus.connecting
              : SvcStatus.notReady;
      try {
        stateGlobal.videoConnCount.value = status['video_conn_count'] as int;
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    funtiHomeBannerHidden.removeListener(_onBannerChanged);
    _statusTimer?.cancel();
    super.dispose();
  }

  void _hideBanner() => setFuntiHomeBannerHidden(true);

  void _onBannerChanged() {
    if (mounted) setState(() {});
  }

  // Height of the banner and notices above the cards, measured after layout:
  // the cards take the rest of the window, but never less than they need.
  final _topKey = GlobalKey();
  double _topHeight = 0;

  void _measureTop() {
    final box = _topKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if ((box.size.height - _topHeight).abs() > 0.5) {
      setState(() => _topHeight = box.size.height);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureTop());
    return Container(
      color: t.bg,
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              const padding = EdgeInsets.fromLTRB(28, 20, 28, 20);
              // Narrower than this the connect field becomes unusable.
              const minWidth = 720.0;
              // "This computer" shows ID, password and permanent access.
              const minCardsHeight = 470.0;
              final width = c.maxWidth < minWidth ? minWidth : c.maxWidth;
              final inner = width - padding.horizontal;
              final leftWidth = (inner * 0.42).clamp(320.0, 372.0);
              final freeHeight = c.maxHeight - padding.vertical - _topHeight;
              final cardsHeight =
                  freeHeight < minCardsHeight ? minCardsHeight : freeHeight;
              Widget body = SingleChildScrollView(
                child: Padding(
                  padding: padding,
                  child: SizedBox(
                    width: inner,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Column(
                          key: _topKey,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!_bannerHidden) ...[
                              _Banner(onClose: _hideBanner),
                              const SizedBox(height: 16),
                            ],
                            widget.notices,
                          ],
                        ),
                        SizedBox(
                          height: cardsHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (widget.showThisComputer) ...[
                                SizedBox(
                                    width: leftWidth,
                                    child: const _ThisComputerCard()),
                                const SizedBox(width: 20),
                              ],
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _ConnectCard(),
                                    SizedBox(height: 16),
                                    Expanded(child: _MyDevicesCard()),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              if (width > c.maxWidth) {
                body = SingleChildScrollView(
                    scrollDirection: Axis.horizontal, child: body);
              }
              return body;
            }),
          ),
          const _StatusBar(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Container(
      padding: padding ?? const EdgeInsets.fromLTRB(24, 20, 24, 20),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.stroke),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: t.muted,
      ),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: t.surface2,
            foregroundColor: t.text,
            side: BorderSide(color: t.stroke),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Icon(icon, size: 18),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

void _copy(String text) {
  Clipboard.setData(ClipboardData(text: text));
  showToast(translate('Copied'));
}

// ---------------------------------------------------------------------------
// Banner

class _Banner extends StatelessWidget {
  const _Banner({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Container(
      height: 212,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.banner,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.stroke),
      ),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 300,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 8, 0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        translate('funti-home-banner-title'),
                        style: TextStyle(
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        translate('funti-home-banner-text'),
                        style: TextStyle(
                            fontSize: 13, height: 1.5, color: t.muted),
                      ),
                    ],
                  ),
                ),
              ),
              const Expanded(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: FuntiHomeScene(),
                ),
              ),
            ],
          ),
          Positioned(
            right: 10,
            top: 10,
            child: Tooltip(
              message: translate('funti-home-banner-hide'),
              child: Material(
                color: t.text.withOpacity(0.06),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onClose,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(Icons.close, size: 14, color: t.muted),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// This computer

class _ThisComputerCard extends StatefulWidget {
  const _ThisComputerCard();

  @override
  State<_ThisComputerCard> createState() => _ThisComputerCardState();
}

class _ThisComputerCardState extends State<_ThisComputerCard> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  Timer? _timer;
  bool _permanentPasswordSet = false;

  @override
  void initState() {
    super.initState();
    _timer = periodic_immediate(const Duration(seconds: 1), () async {
      final set =
          await bind.mainGetCommon(key: 'permanent-password-set') == 'true';
      if (mounted && set != _permanentPasswordSet) {
        setState(() => _permanentPasswordSet = set);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Security options are locked in an installed client until the owner
  /// confirms with administrator rights or the unlock PIN, exactly as on
  /// the "Security" settings page. The home screen must not bypass that.
  void _withUnlock(VoidCallback action) async {
    if (!bind.mainIsInstalled()) {
      action();
      return;
    }
    final unlockPin = bind.mainGetUnlockPin();
    if (unlockPin.isEmpty || isUnlockPinDisabled()) {
      if (await callMainCheckSuperUserPermission()) {
        action();
      }
    } else {
      checkUnlockPinDialog(unlockPin, action);
    }
  }

  Future<void> _setPermanentAccess(ServerModel model, bool on) async {
    if (on) {
      Future<void> enable() async {
        await model.setVerificationMethod(kUseBothPasswords);
        await model.updatePasswordModel();
      }

      if (_permanentPasswordSet) {
        await enable();
      } else {
        setPasswordDialog(notEmptyCallback: enable);
      }
    } else {
      // Fail closed: turning permanent access off also forgets the password.
      await model.setVerificationMethod(kUseTemporaryPassword);
      await bind.mainSetPermanentPasswordWithResult(password: '');
      await model.updatePasswordModel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, _) => _buildCard(context, model),
      ),
    );
  }

  String _shareText(ServerModel model, bool withPassword) {
    final lines = [
      '${translate('funti-share-title')} ${Platform.localHostname}',
      'ID: ${model.serverId.text}',
      if (withPassword)
        '${translate('One-time Password')}: ${model.serverPasswd.text}',
    ];
    return lines.join('\n');
  }

  Widget _buildCard(BuildContext context, ServerModel model) {
    // Permanent access sits at the bottom of the card; when the window is
    // too low for everything, the card scrolls instead of cutting it off.
    return _Card(
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(child: _cardContent(context, model)),
          ),
        ),
      ),
    );
  }

  Widget _cardContent(BuildContext context, ServerModel model) {
    final t = FuntiTokens.of(context);
    final showOneTime = model.approveMode != 'click' &&
        model.verificationMethod != kUsePermanentPassword;
    final permanentOn = _permanentPasswordSet &&
        model.verificationMethod != kUseTemporaryPassword;
    final permanentLocked = isChangePermanentPasswordDisabled() ||
        isOptionFixed(kOptionVerificationMethod);
    final labelStyle = TextStyle(fontSize: 13, color: t.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _SectionTitle(translate('This computer'))),
            Obx(() => _StatusPill(
                  stopped: _svcStopped.value,
                  status: stateGlobal.svcStatus.value,
                )),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          Platform.localHostname,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: t.text,
          ),
        ),
        const SizedBox(height: 14),
        Text(translate('ID for connection'), style: labelStyle),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                model.serverId.text,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: t.text,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _SquareButton(
              icon: Icons.copy_rounded,
              tooltip: translate('Copy ID'),
              onPressed: () => _copy(model.serverId.text.replaceAll(' ', '')),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(translate('One-time Password'), style: labelStyle),
        const SizedBox(height: 6),
        if (showOneTime) ...[
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  model.serverPasswd.text,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                    fontFamily: 'Consolas',
                    color: t.text,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _SquareButton(
                icon: Icons.refresh_rounded,
                tooltip: translate('Refresh Password'),
                onPressed: () => bind.mainUpdateTemporaryPassword(),
              ),
              const SizedBox(width: 8),
              _SquareButton(
                icon: Icons.copy_rounded,
                tooltip: translate('Copy password'),
                onPressed: () => _copy(model.serverPasswd.text),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(translate('funti-otp-rotates-tip'),
              style: TextStyle(fontSize: 12, color: t.muted)),
        ] else
          Text(translate('funti-otp-off-tip'),
              style: TextStyle(fontSize: 14, color: t.muted)),
        const SizedBox(height: 14),
        // Ready-to-send text for a messenger: who, ID and the password.
        OutlinedButton.icon(
          onPressed: () => _copy(_shareText(model, showOneTime)),
          style: OutlinedButton.styleFrom(
            foregroundColor: t.link,
            side: BorderSide(color: t.stroke),
            minimumSize: const Size(0, 40),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          icon: const Icon(Icons.ios_share_rounded, size: 18),
          label: Text(translate(
              showOneTime ? 'funti-copy-id-and-password' : 'Copy ID')),
        ),
        // FUNTIDESK (ADR-006): one button for "come and help me", sent to the
        // family; shown once this computer has family members.
        if (funtiFamilyMembers().isNotEmpty) ...[
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: showFuntiAskHelpDialog,
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: t.accent,
              foregroundColor: t.onAccent,
              minimumSize: const Size(0, 40),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.support_agent_rounded, size: 18),
            label: Text(translate('funti-help-ask')),
          ),
        ],
        const SizedBox(height: 14),
        const Spacer(),
        Container(
          padding: const EdgeInsets.only(top: 14),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.stroke)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      translate('Permanent access'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      translate(permanentOn
                          ? 'funti-permanent-on-tip'
                          : 'funti-permanent-off-tip'),
                      style:
                          TextStyle(fontSize: 12, height: 1.4, color: t.muted),
                    ),
                    if (permanentOn && !permanentLocked)
                      InkWell(
                        onTap: () => _withUnlock(() => setPasswordDialog()),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            translate('Change Password'),
                            style: TextStyle(fontSize: 12, color: t.link),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Switch(
                value: permanentOn,
                activeColor: t.onAccent,
                activeTrackColor: t.accent,
                inactiveThumbColor: t.muted,
                inactiveTrackColor: t.surface2,
                trackOutlineColor: WidgetStatePropertyAll(t.inputStroke),
                onChanged: permanentLocked
                    ? null
                    : (on) => _withUnlock(() => _setPermanentAccess(model, on)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.stopped, required this.status});

  final bool stopped;
  final SvcStatus status;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final online = !stopped && status == SvcStatus.ready;
    final text = stopped
        ? translate('funti-status-stopped')
        : status == SvcStatus.ready
            ? translate('funti-status-online')
            : status == SvcStatus.connecting
                ? translate('funti-status-connecting')
                : translate('funti-status-offline');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: online ? t.okBg : t.surface2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(online ? t.ok : t.off),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: online ? t.okText : t.muted,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connect

class _ConnectCard extends StatefulWidget {
  const _ConnectCard();

  @override
  State<_ConnectCard> createState() => _ConnectCardState();
}

class _ConnectCardState extends State<_ConnectCard> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _peersLoader = AllPeersLoader();

  @override
  void initState() {
    super.initState();
    _peersLoader.init(setState);
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _peersLoader.needLoad) {
        _peersLoader.getAllPeers();
      }
    });
    // `connect()` writes the chosen ID back into the field registered here.
    Get.put<TextEditingController>(_controller);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final last = await bind.mainGetLastRemoteId();
      if (mounted && _controller.text.isEmpty && last.isNotEmpty) {
        _controller.text = formatID(last);
      }
    });
  }

  @override
  void dispose() {
    _peersLoader.clear();
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  static String _peerName(Peer p) =>
      p.alias.isNotEmpty ? p.alias : (p.hostname.isNotEmpty ? p.hostname : '');

  Iterable<Peer> _matches(String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final digits = q.replaceAll(' ', '');
    return _peersLoader.peers.where((p) =>
        p.id.contains(digits) ||
        p.alias.toLowerCase().contains(q) ||
        p.hostname.toLowerCase().contains(q));
  }

  /// Accepts an ID or the name of a known device.
  String? _resolve(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return null;
    final compact = raw.replaceAll(' ', '');
    if (RegExp(r'^\d+$').hasMatch(compact)) return compact;
    final q = raw.toLowerCase();
    final exact = _peersLoader.peers.where(
        (p) => p.alias.toLowerCase() == q || p.hostname.toLowerCase() == q);
    if (exact.length == 1) return exact.first.id;
    final partial = _matches(raw).toList();
    if (partial.length == 1) return partial.first.id;
    // Not a number and not a known name: let the core decide (it also
    // accepts IDs with a server suffix).
    return exact.isEmpty && partial.isEmpty && !raw.contains(' ') ? raw : null;
  }

  void _connect(
      {bool isFileTransfer = false,
      bool isViewCamera = false,
      bool isTerminal = false}) {
    final id = _resolve(_controller.text);
    if (id == null) {
      showToast(translate('funti-device-not-found'));
      return;
    }
    connect(context, id,
        isFileTransfer: isFileTransfer,
        isViewCamera: isViewCamera,
        isTerminal: isTerminal);
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: t.inputStroke),
    );
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(translate('Connect')),
          const SizedBox(height: 12),
          Text(translate('funti-target-label'),
              style: TextStyle(fontSize: 13, color: t.muted)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: RawAutocomplete<Peer>(
                  textEditingController: _controller,
                  focusNode: _focusNode,
                  optionsBuilder: (value) {
                    final options = _matches(value.text).take(6).toList();
                    _peersLoader.queryOnlines(options);
                    return options;
                  },
                  displayStringForOption: (p) => formatID(p.id),
                  fieldViewBuilder: (context, controller, focusNode, _) =>
                      TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: TextStyle(fontSize: 16, color: t.text),
                    cursorColor: t.text,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: t.input,
                      hintText: translate('funti-target-hint'),
                      hintStyle: TextStyle(color: t.muted),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 15),
                      border: border,
                      enabledBorder: border,
                      focusedBorder: border.copyWith(
                          borderSide: BorderSide(color: t.accent, width: 1.5)),
                    ),
                    onSubmitted: (_) => _connect(),
                  ),
                  optionsViewBuilder: (context, onSelected, options) => Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      color: t.surface,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(maxWidth: 420, maxHeight: 280),
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          children: options
                              .map((p) => InkWell(
                                    onTap: () => onSelected(p),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 9),
                                      child: Row(
                                        children: [
                                          _Dot(p.online ? t.ok : t.off),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              _peerName(p).isEmpty
                                                  ? formatID(p.id)
                                                  : '${_peerName(p)} · ${formatID(p.id)}',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 14, color: t.text),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _connect,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: t.accent,
                    foregroundColor: t.onAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  child: Text(translate('Connect')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            children: [
              _LinkButton(
                icon: Icons.folder_outlined,
                text: translate('funti-transfer-files-only'),
                onTap: () => _connect(isFileTransfer: true),
              ),
              _LinkButton(
                icon: Icons.video_call_outlined,
                text: translate('funti-call'),
                onTap: () => _connect(isViewCamera: true),
              ),
              _LinkButton(
                icon: Icons.terminal_rounded,
                text: translate('funti-open-terminal'),
                onTap: () => _connect(isTerminal: true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton(
      {required this.icon, required this.text, required this.onTap});

  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: t.link,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        textStyle: const TextStyle(fontSize: 13),
      ),
      icon: Icon(icon, size: 16),
      label: Text(text),
    );
  }
}

// ---------------------------------------------------------------------------
// My devices

class _MyDevicesCard extends StatefulWidget {
  const _MyDevicesCard();

  @override
  State<_MyDevicesCard> createState() => _MyDevicesCardState();
}

class _MyDevicesCardState extends State<_MyDevicesCard> {
  // 0: recent, 1: favorites, 2: family (ADR-006).
  int _tab = 0;
  bool get _favorites => _tab == 1;
  Timer? _onlineTimer;
  Timer? _familyTimer;
  List<FuntiFamilyMember> _family = funtiFamilyMembers();

  Peers get _model =>
      _favorites ? gFFI.favoritePeersModel : gFFI.recentPeersModel;

  @override
  void initState() {
    super.initState();
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    gFFI.recentPeersModel.addListener(_onPeers);
    gFFI.favoritePeersModel.addListener(_onPeers);
    _onlineTimer = periodic_immediate(const Duration(seconds: 20), () async {
      _queryOnlines();
    });
    // The family list is changed by the service (pairing on the other side).
    _familyTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final family = funtiFamilyMembers();
      if (mounted && !listEquals(family, _family)) {
        setState(() => _family = family);
      }
    });
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    _familyTimer?.cancel();
    gFFI.recentPeersModel.removeListener(_onPeers);
    gFFI.favoritePeersModel.removeListener(_onPeers);
    super.dispose();
  }

  void _onPeers() {
    if (!mounted) return;
    final loaded = gFFI.recentPeersModel.event == UpdateEvent.load ||
        gFFI.favoritePeersModel.event == UpdateEvent.load;
    setState(() {});
    if (loaded) _queryOnlines();
  }

  void _queryOnlines() {
    final ids = {
      ...gFFI.recentPeersModel.peers.map((p) => p.id),
      ...gFFI.favoritePeersModel.peers.map((p) => p.id),
    }.toList();
    if (ids.isNotEmpty) bind.queryOnlines(ids: ids);
  }

  Future<void> _toggleFavorite(Peer peer, bool isFav) async {
    final favs = (await bind.mainGetFav()).toList();
    if (isFav) {
      favs.remove(peer.id);
    } else if (!favs.contains(peer.id)) {
      favs.add(peer.id);
    }
    await bind.mainStoreFav(favs: favs);
    bind.mainLoadFavPeers();
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final peers = _model.peers;
    final favIds = gFFI.favoritePeersModel.peers.map((p) => p.id).toSet();
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 20, 10),
            child: Row(
              children: [
                Expanded(child: _SectionTitle(translate('My devices'))),
                _Segmented(
                  labels: [
                    translate('funti-tab-recent'),
                    translate('funti-tab-favorites'),
                    translate('funti-tab-family'),
                  ],
                  selected: _tab,
                  onSelected: (i) => setState(() {
                    _tab = i;
                    if (i == 2) _family = funtiFamilyMembers();
                  }),
                ),
              ],
            ),
          ),
          if (_tab == 2)
            Expanded(
              child: _FamilyList(
                members: _family,
                onChanged: () =>
                    setState(() => _family = funtiFamilyMembers()),
              ),
            )
          else
          Expanded(
            child: peers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        translate(_favorites
                            ? 'funti-favorites-empty'
                            : 'funti-recent-empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: t.muted),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: peers.length,
                    itemBuilder: (context, i) => _DeviceRow(
                      peer: peers[i],
                      inFavorites: _favorites,
                      isFav: favIds.contains(peers[i].id),
                      onToggleFav: () => _toggleFavorite(
                          peers[i], favIds.contains(peers[i].id)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented(
      {required this.labels, required this.selected, required this.onSelected});

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++)
            Semantics(
              selected: i == selected,
              button: true,
              child: Material(
                color: i == selected ? t.raised : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onSelected(i),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            i == selected ? FontWeight.w600 : FontWeight.w400,
                        color: i == selected ? t.text : t.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Family (ADR-006)

enum _FamilyAction { connect, files, terminal, help, rename, remove }

class _FamilyList extends StatelessWidget {
  const _FamilyList({required this.members, required this.onChanged});

  final List<FuntiFamilyMember> members;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    // What family means stays visible, not only while the list is empty.
    final add = Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate('funti-family-about'),
              style: TextStyle(fontSize: 12.5, color: t.muted)),
          const SizedBox(height: 2),
          TextButton.icon(
            onPressed: () => showFuntiFamilyAddDialog(onChanged: onChanged),
            icon: const Icon(Icons.group_add_outlined, size: 18),
            label: Text(translate('funti-family-add')),
            style: TextButton.styleFrom(
                foregroundColor: t.link, padding: EdgeInsets.zero),
          ),
        ],
      ),
    );
    if (members.isEmpty) {
      return Column(
        children: [
          add,
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  translate('funti-family-empty'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: t.muted),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        add,
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            itemCount: members.length,
            itemBuilder: (context, i) =>
                _FamilyRow(member: members[i], onChanged: onChanged),
          ),
        ),
      ],
    );
  }
}

class _FamilyRow extends StatelessWidget {
  const _FamilyRow({required this.member, required this.onChanged});

  final FuntiFamilyMember member;
  final VoidCallback onChanged;

  void _onAction(BuildContext context, _FamilyAction action) {
    switch (action) {
      case _FamilyAction.connect:
        connect(context, member.id);
        break;
      case _FamilyAction.files:
        connect(context, member.id, isFileTransfer: true);
        break;
      case _FamilyAction.terminal:
        connect(context, member.id, isTerminal: true);
        break;
      case _FamilyAction.help:
        funtiAskHelpFrom(member);
        break;
      case _FamilyAction.rename:
        showFuntiFamilyRenameDialog(member, onChanged: onChanged);
        break;
      case _FamilyAction.remove:
        showFuntiFamilyRemoveDialog(member, onChanged: onChanged);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final style = TextStyle(fontSize: 14, color: t.text);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.rowStroke)),
      ),
      child: Row(
        children: [
          Icon(Icons.family_restroom_rounded, size: 22, color: t.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: t.text)),
                const SizedBox(height: 2),
                Text('ID ${formatFuntiId(member.id)}',
                    style: TextStyle(fontSize: 12.5, color: t.muted)),
              ],
            ),
          ),
          IconButton(
            tooltip: translate('funti-call'),
            onPressed: () => connect(context, member.id, isViewCamera: true),
            icon: Icon(Icons.video_call_outlined, color: t.link),
          ),
          PopupMenuButton<_FamilyAction>(
            tooltip: translate('More'),
            color: t.surface,
            splashRadius: 18,
            icon: Icon(Icons.more_horiz_rounded, size: 20, color: t.muted),
            onSelected: (a) => _onAction(context, a),
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: _FamilyAction.connect,
                  child: Text(translate('Connect'), style: style)),
              PopupMenuItem(
                  value: _FamilyAction.files,
                  child: Text(translate('funti-transfer-files-only'),
                      style: style)),
              PopupMenuItem(
                  value: _FamilyAction.terminal,
                  child: Text(translate('funti-open-terminal'), style: style)),
              PopupMenuItem(
                  value: _FamilyAction.help,
                  child: Text(translate('funti-help-ask'), style: style)),
              const PopupMenuDivider(),
              PopupMenuItem(
                  value: _FamilyAction.rename,
                  child: Text(translate('Rename'), style: style)),
              PopupMenuItem(
                  value: _FamilyAction.remove,
                  child: Text(translate('funti-family-remove'), style: style)),
            ],
          ),
        ],
      ),
    );
  }
}

enum _DeviceAction { files, camera, terminal, rename, relay, remove }

class _DeviceRow extends StatelessWidget {
  const _DeviceRow(
      {required this.peer,
      required this.inFavorites,
      required this.isFav,
      required this.onToggleFav});

  final Peer peer;
  final bool inFavorites;
  final bool isFav;
  final VoidCallback onToggleFav;

  static void _reload() {
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
  }

  void _onAction(BuildContext context, _DeviceAction action, bool forceRelay) {
    switch (action) {
      case _DeviceAction.files:
        connect(context, peer.id, isFileTransfer: true);
        break;
      case _DeviceAction.camera:
        connect(context, peer.id, isViewCamera: true);
        break;
      case _DeviceAction.terminal:
        connect(context, peer.id, isTerminal: true);
        break;
      case _DeviceAction.rename:
        renameDialog(
          oldName: peer.alias,
          onSubmit: (newName) async {
            if (newName == peer.alias) return;
            await bind.mainSetPeerAlias(id: peer.id, alias: newName);
            _reload();
          },
        );
        break;
      case _DeviceAction.relay:
        // Per-device transport preference, as in the upstream peer card.
        // It is deliberately not a main-screen setting (docs/PRODUCT.md).
        bind
            .mainSetPeerOption(
                id: peer.id,
                key: kOptionForceAlwaysRelay,
                value: bool2option(kOptionForceAlwaysRelay, !forceRelay))
            .then((_) => showToast(translate('Successful')));
        break;
      case _DeviceAction.remove:
        final name = peer.alias.isEmpty ? formatID(peer.id) : peer.alias;
        deleteConfirmDialog(() async {
          if (inFavorites) {
            final favs = (await bind.mainGetFav()).toList();
            if (favs.remove(peer.id)) await bind.mainStoreFav(favs: favs);
          } else {
            await bind.mainRemovePeer(id: peer.id);
          }
          _reload();
          showToast(translate('Successful'));
        }, '${translate('Delete')} "$name"?');
        break;
    }
  }

  Widget _menu(BuildContext context) {
    final t = FuntiTokens.of(context);
    final forceRelay = option2bool(kOptionForceAlwaysRelay,
        bind.mainGetPeerOptionSync(id: peer.id, key: kOptionForceAlwaysRelay));
    final style = TextStyle(fontSize: 14, color: t.text);
    return PopupMenuButton<_DeviceAction>(
      tooltip: translate('More'),
      color: t.surface,
      splashRadius: 18,
      icon: Icon(Icons.more_horiz_rounded, size: 20, color: t.muted),
      onSelected: (a) => _onAction(context, a, forceRelay),
      itemBuilder: (context) => [
        PopupMenuItem(
            value: _DeviceAction.files,
            child: Text(translate('funti-transfer-files-only'), style: style)),
        PopupMenuItem(
            value: _DeviceAction.camera,
            child: Text(translate('funti-call'), style: style)),
        PopupMenuItem(
            value: _DeviceAction.terminal,
            child: Text(translate('funti-open-terminal'), style: style)),
        const PopupMenuDivider(),
        PopupMenuItem(
            value: _DeviceAction.rename,
            child: Text(translate('Rename'), style: style)),
        CheckedPopupMenuItem(
            value: _DeviceAction.relay,
            checked: forceRelay,
            child: Text(translate('Always connect via relay'), style: style)),
        PopupMenuItem(
            value: _DeviceAction.remove,
            child: Text(translate('Delete'), style: style)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    final name = peer.alias.isNotEmpty
        ? peer.alias
        : (peer.hostname.isNotEmpty ? peer.hostname : formatID(peer.id));
    final status =
        translate(peer.online ? 'funti-status-online' : 'funti-device-offline');
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.rowStroke)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: t.surface2,
        onDoubleTap: () => connect(context, peer.id),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          // Narrow card: drop the device tile and shorten the action so the
          // name and status always keep their room.
          child: LayoutBuilder(builder: (context, c) {
            final compact = c.maxWidth < 460;
            return Row(
              children: [
                if (!compact) ...[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: t.surface2,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.desktop_windows_outlined,
                        size: 19, color: t.muted),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          _Dot(peer.online ? t.ok : t.off),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '$status · ID ${formatID(peer.id)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: t.muted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: translate(
                      isFav ? 'Remove from Favorites' : 'Add to Favorites'),
                  child: IconButton(
                    onPressed: onToggleFav,
                    splashRadius: 18,
                    icon: Icon(
                      isFav ? Icons.star_rounded : Icons.star_outline_rounded,
                      size: 20,
                      color: isFav ? t.star : t.muted,
                    ),
                  ),
                ),
                _menu(context),
                const SizedBox(width: 4),
                if (compact)
                  peer.online
                      ? IconButton.outlined(
                          tooltip: translate('Connect'),
                          onPressed: () => connect(context, peer.id),
                          color: t.link,
                          style: IconButton.styleFrom(
                              side: BorderSide(color: t.accent)),
                          icon:
                              const Icon(Icons.arrow_forward_rounded, size: 18),
                        )
                      : const SizedBox(width: 40)
                else
                  SizedBox(
                    width: 132,
                    child: peer.online
                        ? OutlinedButton(
                            onPressed: () => connect(context, peer.id),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: t.link,
                              side: BorderSide(color: t.accent),
                              minimumSize: const Size(0, 34),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                              textStyle: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            child: Text(translate('Connect')),
                          )
                        : Text(
                            translate('funti-device-unavailable'),
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 12, color: t.muted),
                          ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status bar

class _StatusBar extends StatefulWidget {
  const _StatusBar();

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  String _version = '';

  @override
  void initState() {
    super.initState();
    bind.mainGetVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = FuntiTokens.of(context);
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: BoxDecoration(
        color: t.chrome,
        border: Border(top: BorderSide(color: t.stroke)),
      ),
      child: Obx(() {
        final stopped = _svcStopped.value;
        final status = stateGlobal.svcStatus.value;
        final online = !stopped && status == SvcStatus.ready;
        final text = stopped
            ? translate('funti-status-stopped')
            : status == SvcStatus.ready
                ? translate('funti-net-online')
                : status == SvcStatus.connecting
                    ? translate('funti-net-connecting')
                    : translate('funti-net-offline');
        final style = TextStyle(fontSize: 12, color: t.muted);
        return Row(
          children: [
            _Dot(online ? t.ok : t.off),
            const SizedBox(width: 8),
            Text(text, style: style),
            if (stopped) ...[
              const SizedBox(width: 12),
              InkWell(
                onTap: () => start_service(true),
                child: Text(translate('Start service'),
                    style: style.copyWith(
                        color: t.link, decoration: TextDecoration.underline)),
              ),
            ],
            const Spacer(),
            if (_version.isNotEmpty) Text('v$_version', style: style),
          ],
        );
      }),
    );
  }
}
