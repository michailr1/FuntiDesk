// FuntiDesk design system: visual constants and reusable widgets for the
// Windows 11-inspired dark desktop shell.
//
// This file intentionally contains NO business logic: it only exposes
// color/space constants and presentational widgets that the existing pages
// (desktop_home_page, connection_page) compose on top of unchanged models
// and controllers.

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';

import '../../consts.dart';
import '../../common.dart';
import '../../common/shared_state.dart';

/// Windows 11-like dark palette used by the FuntiDesk desktop shell.
class FuntiColors {
  FuntiColors._();

  /// Window / scaffold background (Win11 dark "mica" base).
  static const Color scaffold = Color(0xFF1C1C22);

  /// Navigation rail background.
  static const Color rail = Color(0xFF14141A);

  /// Elevated surface for cards.
  static const Color card = Color(0xFF242430);

  /// Slightly lighter surface for hovered cards / inputs.
  static const Color cardHover = Color(0xFF2B2B39);

  /// FuntiDesk accent blue.
  static const Color accent = Color(0xFF3B82F6);

  /// Accent pressed/hover variant.
  static const Color accentHover = Color(0xFF2F6FE4);

  /// Subtle stroke around cards.
  static const Color cardStroke = Color(0x14FFFFFF);

  /// Text: high emphasis.
  static const Color textHigh = Color(0xFFF2F2F7);

  /// Text: medium emphasis (labels, hints).
  static const Color textMedium = Color(0xB3F2F2F7);

  /// Text: low emphasis (captions).
  static const Color textLow = Color(0x66F2F2F7);

  /// Success green for the "ready" status dot.
  static const Color statusReady = Color(0xFF34C77B);

  /// Warn amber.
  static const Color statusWarn = Color(0xFFF5A623);

  /// Error red.
  static const Color statusError = Color(0xFFE0555F);
}

/// Radius / spacing tokens (Windows 11 rounding scale).
class FuntiRadius {
  FuntiRadius._();

  /// Cards and tiles.
  static const double card = 10.0;

  /// Buttons.
  static const double button = 6.0;

  /// Small chips / status pills.
  static const double pill = 999.0;

  /// Standard horizontal card padding.
  static const EdgeInsets cardPadding = EdgeInsets.all(16.0);
}

/// The left navigation rail of the FuntiDesk main window.
///
/// Items map to existing functionality only:
/// - "Connection" — the current connection page (active slice).
/// - "Devices", "History" — disabled placeholders for future slices.
/// - "Settings" — opens the existing DesktopSettingPage.
class FuntiNavRail extends StatefulWidget {
  const FuntiNavRail({
    Key? key,
    required this.onOpenSettings,
  }) : super(key: key);

  /// Invoked when the user picks the Settings entry.
  final VoidCallback onOpenSettings;

  @override
  State<FuntiNavRail> createState() => _FuntiNavRailState();
}

enum _NavItem { connection, devices, history, settings }

class _FuntiNavRailState extends State<FuntiNavRail> {
  _NavItem _selected = _NavItem.connection;

  static const _items = {
    _NavItem.connection: (Icons.computer_outlined, 'Connection'),
    _NavItem.devices: (Icons.devices_other_outlined, 'Devices'),
    _NavItem.history: (Icons.history_outlined, 'History'),
    _NavItem.settings: (Icons.settings_outlined, 'Settings'),
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76.0,
      color: FuntiColors.rail,
      child: Column(
        children: [
          // Brand block.
          Padding(
            padding: const EdgeInsets.only(top: 18.0, bottom: 14.0),
            child: _buildBrand(),
          ),
          ..._items.entries.map((entry) => _buildTile(entry.key, entry.value)),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildBrand() {
    return Tooltip(
      message: 'FuntiDesk',
      child: Container(
        width: 40.0,
        height: 40.0,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10.0),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [FuntiColors.accent, Color(0xFF2563EB)],
          ),
        ),
        child: const Center(
          child: Text(
            'F',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTile(_NavItem item, (IconData, String) spec) {
    final (icon, labelKey) = spec;
    final enabled = item == _NavItem.connection || item == _NavItem.settings;
    final selected = item == _selected && enabled;
    final label = translate(labelKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0, horizontal: 10.0),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.35,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(FuntiRadius.button),
            onTap: () {
              if (!enabled) return;
              if (item == _NavItem.settings) {
                widget.onOpenSettings();
                return;
              }
              setState(() => _selected = item);
            },
            child: Container(
              decoration: BoxDecoration(
                color: selected ? FuntiColors.cardHover : Colors.transparent,
                borderRadius: BorderRadius.circular(FuntiRadius.button),
              ),
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color:
                        selected ? FuntiColors.accent : FuntiColors.textMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          selected ? FuntiColors.textHigh : FuntiColors.textLow,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded surface card used for ID / password / connect panels.
class FuntiCard extends StatelessWidget {
  const FuntiCard({Key? key, required this.child, this.padding})
      : super(key: key);

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? FuntiRadius.cardPadding,
      decoration: BoxDecoration(
        color: FuntiColors.card,
        borderRadius: BorderRadius.circular(FuntiRadius.card),
        border: Border.all(color: FuntiColors.cardStroke),
      ),
      child: child,
    );
  }
}

/// A compact status pill, e.g. the service "Ready" indicator.
class FuntiStatusPill extends StatelessWidget {
  const FuntiStatusPill({
    Key? key,
    required this.color,
    required this.label,
  }) : super(key: key);

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: FuntiColors.card,
        borderRadius: BorderRadius.circular(FuntiRadius.pill),
        border: Border.all(color: FuntiColors.cardStroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8.0,
            height: 8.0,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 8.0),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: FuntiColors.textMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The prominent accent-filled "Connect" button.
class FuntiConnectButton extends StatelessWidget {
  const FuntiConnectButton({Key? key, required this.onPressed})
      : super(key: key);

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: FuntiColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: FuntiColors.accent.withOpacity(0.35),
        disabledForegroundColor: Colors.white70,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 14.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FuntiRadius.button),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Text(translate('Connect')),
    );
  }
}

/// Section header for the redesigned home screen.
class FuntiSectionHeader extends StatelessWidget {
  const FuntiSectionHeader({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: FuntiColors.textMedium,
        ),
      ),
    );
  }
}

/// Small helper so callers can use FuntiColors without importing common.dart.
Color funtiStatusColor(SvcStatus status, {required bool svcStopped}) {
  if (svcStopped || status == SvcStatus.connecting) {
    return FuntiColors.statusWarn;
  }
  return status == SvcStatus.ready
      ? FuntiColors.statusReady
      : FuntiColors.statusError;
}

/// Compact transport chip for an active remote session: green "P2P" for a
/// direct connection, amber "Relay" for a relayed one.
///
/// Product requirement (M3 validates both direct P2P and relay fallback):
/// the transport mode must be visible in the session UI. The state is read
/// from the existing runtime [ConnectionTypeState] (GetX tag
/// `connection_type_<id>`), which is already fed by real session events in
/// models/model.dart (setDirect on ConnectionReady) — no protocol change.
/// `direct == null` means the runtime has not reported transport yet; the
/// chip then shows a neutral "Connecting..." state instead of guessing.
class FuntiTransportChip extends StatelessWidget {
  const FuntiTransportChip({Key? key, required this.peerId}) : super(key: key);

  final String peerId;

  @override
  Widget build(BuildContext context) {
    final tag = ConnectionTypeState.tag(peerId);
    final registered = Get.isRegistered<ConnectionType>(tag: tag);
    if (!registered) {
      // Session state not initialized yet (e.g. web): show a neutral chip
      // instead of throwing. Never guess the transport mode.
      return _buildChip(
        color: FuntiColors.textLow,
        label: '...',
        tooltip: translate('connecting_status'),
      );
    }
    final connType = Get.find<ConnectionType>(tag: tag);
    return Obx(() {
      final direct = connType.direct.value;
      final secure = connType.secure.value;
      final known = direct != kInvalidValueStr;
      final isDirect = known && direct == ConnectionType.strDirect;
      final color = !known
          ? FuntiColors.textLow
          : (isDirect ? FuntiColors.statusReady : FuntiColors.statusWarn);
      final label = !known ? '...' : (isDirect ? 'P2P' : 'Relay');
      final tooltip = !known
          ? translate('connecting_status')
          : getConnectionText(secure != ConnectionType.strInsecure, isDirect,
              connType.stream_type.value);
      return _buildChip(color: color, label: label, tooltip: tooltip);
    });
  }

  Widget _buildChip(
      {required Color color, required String label, required String tooltip}) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
        decoration: BoxDecoration(
          color: FuntiColors.card,
          borderRadius: BorderRadius.circular(FuntiRadius.pill),
          border: Border.all(color: FuntiColors.cardStroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7.0,
              height: 7.0,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 6.0),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: FuntiColors.textMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Transport preference the user picks before connecting.
enum FuntiTransportPreference {
  /// Try direct/P2P first, fall back to relay when needed (engine default).
  auto,

  /// Force the existing relay path (forceRelay, no P2P punch attempt).
  relay,
}

/// Segmented "Auto | Relay" transport selector shown next to the Remote ID.
///
/// Semantics (honest, no simulated modes):
/// - Auto: the engine tries a direct P2P connection first and falls back to
///   the relay automatically when P2P is not possible. Mapped to the
///   existing `connect(forceRelay: false)` path — no new protocol options.
/// - Relay: forces the relay path for this connection via the existing
///   `connect(forceRelay: true)` argument, which flows through
///   connectMainDesktop -> multi-window session args -> Rust
///   session_add(force_relay). Per-connection only; it does not touch the
///   persisted per-peer "force-always-relay" option.
/// - P2P-only: NOT offered. The core has no "forbid relay fallback" switch
///   (client.rs always falls back to request_relay when direct fails), so a
///   hard P2P-only mode would be fake. Auto already tries P2P first.
class FuntiTransportSelector extends StatelessWidget {
  const FuntiTransportSelector({
    Key? key,
    required this.preference,
    required this.onChanged,
  }) : super(key: key);

  final FuntiTransportPreference preference;
  final ValueChanged<FuntiTransportPreference> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: translate('transport_selector_tip'),
      child: Container(
        padding: const EdgeInsets.all(3.0),
        decoration: BoxDecoration(
          color: FuntiColors.card,
          borderRadius: BorderRadius.circular(FuntiRadius.button),
          border: Border.all(color: FuntiColors.cardStroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _segment(
              active: preference == FuntiTransportPreference.auto,
              label: translate('Auto'),
              onTap: () => onChanged(FuntiTransportPreference.auto),
            ),
            _segment(
              active: preference == FuntiTransportPreference.relay,
              label: translate('Relay'),
              onTap: () => onChanged(FuntiTransportPreference.relay),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment({
    required bool active,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(FuntiRadius.button - 1),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: active ? FuntiColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(FuntiRadius.button - 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : FuntiColors.textMedium,
          ),
        ),
      ),
    );
  }
}

// Keep a reference to the app type constant so the shell stays a single source.
const funtiAppTypeMain = kAppTypeMain;
