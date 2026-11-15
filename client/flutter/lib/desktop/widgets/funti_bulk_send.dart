// FUNTIDESK (ADR-024, stage 6): send files to several computers — for each
// one a file transfer session without a window (the same one the file
// window uses), into Downloads or Desktop there; a name already taken gets
// " (2)", " (3)" …, nothing is overwritten.

import 'dart:io';

import 'package:get/get.dart';

import '../../common.dart';
import '../../models/file_model.dart';
import '../../models/model.dart';

const _connectWait = Duration(seconds: 40);
const _transferWait = Duration(minutes: 30);

/// "report.pdf" → "report (2).pdf" if taken.
String funtiFreeName(String name, Set<String> taken) {
  if (!taken.contains(name.toLowerCase())) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2;; i++) {
    final candidate = '$stem ($i)$ext';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
}

Entry _entry(String path) {
  final isDir = FileSystemEntity.isDirectorySync(path);
  final name = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
  return Entry()
    ..path = path
    ..name = name
    ..entryType = isDir ? 1 : 4
    ..size = isDir ? 0 : File(path).lengthSync();
}

/// Sends [paths] to the [folder] ("Downloads" or "Desktop") of computer
/// [id]. Answers like a command: {"code": 0, "output": where} or
/// {"error": translation key or text}.
Future<Map<String, dynamic>> funtiBulkSendOne(
    String id, List<String> paths, String folder) async {
  final tag = 'ft_bulk_$id';
  final ffi = FFI(null);
  Get.put<FFI>(ffi, tag: tag);
  try {
    ffi.start(id, isFileTransfer: true);
    final fm = ffi.fileModel;
    final until = DateTime.now().add(_connectWait);
    while (fm.remoteController.options.value.home.isEmpty) {
      if (DateTime.now().isAfter(until)) return {'error': 'funti-service-offline'};
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final remote = fm.remoteController.options.value;
    final dir = PathUtil.join(remote.home, folder, remote.isWindows);
    final FileDirectory fd;
    try {
      fd = await fm.fileFetcher.fetchDirectory(dir, false, remote.showHidden);
    } catch (_) {
      return {'error': 'funti-send-no-folder'};
    }
    if (fd.path.isEmpty) fd.path = dir;
    final taken = {for (final e in fd.entries) e.name.toLowerCase()};
    final entries = <Entry>[];
    final names = <String>[];
    for (final p in paths) {
      final e = _entry(p);
      final name = funtiFreeName(e.name, taken);
      taken.add(name.toLowerCase());
      entries.add(e);
      names.add(name);
    }
    final ids = await fm.localController
        .funtiSendPaths(entries, DirectoryData(fd, remote), names: names);
    final end = DateTime.now().add(_transferWait);
    while (true) {
      final jobs = fm.jobController.jobTable.where((j) => ids.contains(j.id)).toList();
      final failed = jobs.where((j) => j.state == JobState.error).toList();
      if (failed.isNotEmpty) {
        return {'error': failed.first.err.isEmpty ? 'funti-send-failed' : failed.first.err};
      }
      if (jobs.length == ids.length && jobs.every((j) => j.state == JobState.done)) {
        return {'code': 0, 'output': '${fd.path}: ${names.join(', ')}'};
      }
      if (DateTime.now().isAfter(end)) return {'error': 'funti-send-timeout'};
      await Future.delayed(const Duration(milliseconds: 500));
    }
  } finally {
    await ffi.close();
    await Get.delete<FFI>(tag: tag);
  }
}
