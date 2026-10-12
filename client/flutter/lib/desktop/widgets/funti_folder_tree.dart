// FUNTIDESK: folder tree as in Explorer on the left of a file transfer panel
// (owner's decision 2026-10-11, approved mockup 2026-10-12): quick folders,
// then "This PC" with the drives, folders expand with the arrow. A click
// opens the folder in the panel; the tree itself never changes the panel.
//
// Folders are read with the panel's own FileFetcher, so a remote tree uses
// the same file transfer session and the same permissions as the list.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/file_model.dart';

class _Node {
  _Node(this.name, this.path, this.level);

  final String name;
  final String path;
  final int level;
  bool expanded = false;
  bool loading = false;
  bool failed = false;
  List<_Node>? children;
}

class FuntiFolderTree extends StatefulWidget {
  const FuntiFolderTree(
      {Key? key, required this.controller, required this.onOpen})
      : super(key: key);

  final FileController controller;

  /// Opens a path in the panel; `%VARIABLES%` are expanded by its side.
  final Future<void> Function(String path) onOpen;

  @override
  State<FuntiFolderTree> createState() => _FuntiFolderTreeState();
}

class _FuntiFolderTreeState extends State<FuntiFolderTree> {
  static const _quick = <(String, String)>[
    ('funti-ft-desktop', r'%USERPROFILE%\Desktop'),
    ('funti-ft-documents', r'%USERPROFILE%\Documents'),
    ('funti-ft-downloads', r'%USERPROFILE%\Downloads'),
    ('funti-ft-home', r'%USERPROFILE%'),
  ];

  List<_Node>? _drives;
  bool _drivesFailed = false;
  bool _drivesLoading = false;
  StreamSubscription? _dirSub;

  FileController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _loadDrives();
    // A remote tree may ask before the file transfer session is ready: ask
    // again once the panel has opened a folder.
    _dirSub = _c.directory.listen((_) {
      if (_drives == null) {
        if (!_drivesLoading) _loadDrives();
      } else {
        _reveal();
      }
    });
  }

  @override
  void dispose() {
    _dirSub?.cancel();
    super.dispose();
  }

  Future<List<Entry>> _read(String path) async {
    final fd = await _c.fileFetcher
        .fetchDirectory(path, _c.isLocal, _c.options.value.showHidden);
    fd.format(true);
    return fd.entries;
  }

  Future<void> _loadDrives() async {
    _drivesLoading = true;
    try {
      final entries = await _read('/');
      final drives = entries
          .where((e) => e.isDrive || e.isDirectory)
          .map((e) {
            var path = e.name;
            if (path.endsWith(':')) path = '$path\\';
            return _Node(e.name, path, 0);
          })
          .toList();
      if (mounted) {
        setState(() {
          _drives = drives;
          _drivesFailed = false;
        });
        _reveal();
      }
    } catch (_) {
      if (mounted) setState(() => _drivesFailed = true);
    }
    _drivesLoading = false;
  }

  Future<void> _toggle(_Node node) async {
    if (node.expanded) {
      setState(() => node.expanded = false);
      return;
    }
    await _expand(node);
  }

  int _revealGeneration = 0;

  /// Opens the tree down to the folder shown in the panel, as Explorer does.
  /// Folders the user opened stay open; only the current path is added.
  Future<void> _reveal() async {
    final target = _norm(_c.directory.value.path);
    if (target.length < 2 || target[1] != ':') return;
    final generation = ++_revealGeneration;
    var nodes = _drives;
    while (nodes != null) {
      _Node? next;
      for (final n in nodes) {
        final p = _norm(n.path);
        if (p == target) return;
        if (target.startsWith(p.endsWith(r'\') ? p : '$p\\')) {
          next = n;
          break;
        }
      }
      if (next == null) return;
      if (!next.expanded) await _expand(next);
      if (!mounted || generation != _revealGeneration) return;
      nodes = next.children;
    }
  }

  Future<void> _expand(_Node node) async {
    setState(() {
      node.expanded = true;
      node.failed = false;
    });
    if (node.children != null || node.loading) return;
    setState(() => node.loading = true);
    try {
      final entries = await _read(node.path);
      final dirs = entries.where((e) => e.isDirectory).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      node.children = dirs
          .map((e) => _Node(
              e.name, PathUtil.join(node.path, e.name, true), node.level + 1))
          .toList();
    } catch (_) {
      node.failed = true;
    }
    if (mounted) setState(() => node.loading = false);
  }

  static String _norm(String p) {
    var s = p.replaceAll('/', '\\').toLowerCase();
    while (s.length > 3 && s.endsWith('\\')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  List<_Node> _visible() {
    final out = <_Node>[];
    void walk(List<_Node> nodes) {
      for (final n in nodes) {
        out.add(n);
        if (n.expanded && n.children != null) walk(n.children!);
      }
    }

    walk(_drives ?? const []);
    return out;
  }

  Widget _caption(String key) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
        child: Text(translate(key).toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                color: Theme.of(context).hintColor)),
      );

  Widget _row({
    required String label,
    required int level,
    required bool selected,
    required VoidCallback onTap,
    Widget? leading,
    VoidCallback? onArrow,
    bool expanded = false,
    bool loading = false,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? accent.withOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: EdgeInsets.fromLTRB(4.0 + level * 14, 4, 6, 4),
        child: Row(children: [
          SizedBox(
            width: 20,
            child: loading
                ? const Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 1.5))
                : onArrow == null
                    ? null
                    : InkWell(
                        onTap: onArrow,
                        child: Icon(
                            expanded ? Icons.expand_more : Icons.chevron_right,
                            size: 18)),
          ),
          leading ??
              Icon(Icons.folder_outlined,
                  size: 16, color: Colors.amber.shade800),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13, color: selected ? accent : null)),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final current = _norm(_c.directory.value.path);
      final nodes = _visible();
      return ListView(
        padding: const EdgeInsets.only(right: 4, bottom: 8),
        children: [
          _caption('funti-ft-quick'),
          ..._quick.map((q) => _row(
                label: translate(q.$1),
                level: 0,
                selected: false,
                onTap: () => widget.onOpen(q.$2),
              )),
          _caption('funti-ft-this-pc'),
          if (_drives == null && !_drivesFailed)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (_drivesFailed)
            _row(
              label: translate('funti-ft-this-pc'),
              level: 0,
              selected: current == '/' || current == '\\',
              onTap: () => widget.onOpen('/'),
              leading: const Icon(Icons.computer_outlined, size: 16),
            ),
          ...nodes.map((n) => _row(
                label: n.name,
                level: n.level,
                selected: _norm(n.path) == current,
                onTap: () => widget.onOpen(n.path),
                leading: n.level == 0
                    ? const Icon(Icons.storage_outlined, size: 16)
                    : null,
                onArrow: (n.children?.isEmpty ?? false) && !n.failed
                    ? null
                    : () => _toggle(n),
                expanded: n.expanded,
                loading: n.loading,
              )),
        ],
      );
    });
  }
}
