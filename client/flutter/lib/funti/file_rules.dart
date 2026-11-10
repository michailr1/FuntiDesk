// FUNTIDESK: rules of the file window that do not depend on Flutter, kept
// out of upstream files so that upstream merges touch less and the rules can
// be checked by scripts/ci/test-funti-dart.sh with plain `dart`.
// No imports here: the check runs without `pub get`.

/// "Open" starts only these kinds of files in their program: documents,
/// pictures, sound and video. Everything else (programs, scripts, shortcuts,
/// archives, unknown types) is shown in its folder instead: a list of what
/// is forbidden always misses something.
const funtiOpenable = {
  'txt', 'log', 'md', 'csv', 'pdf', 'rtf', 'doc', 'docx', 'xls', 'xlsx', //
  'ppt', 'pptx', 'odt', 'ods', 'odp', 'jpg', 'jpeg', 'png', 'gif', 'bmp', //
  'webp', 'heic', 'tif', 'tiff', 'mp3', 'wav', 'm4a', 'flac', 'ogg', //
  'mp4', 'mov', 'mkv', 'avi', 'webm',
};

bool funtiIsOpenable(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 &&
      funtiOpenable.contains(name.substring(dot + 1).toLowerCase());
}

/// "name.ext", "name (2).ext", ... — the first one not [taken].
String funtiFreeName(String name, bool Function(String) taken) {
  if (!taken(name)) return name;
  final dot = name.lastIndexOf('.');
  final hasExt = dot > 0;
  final base = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot) : '';
  for (var n = 2;; n++) {
    final candidate = '$base ($n)$ext';
    if (!taken(candidate)) return candidate;
  }
}

/// What to do with names already in the target folder.
enum FuntiConflict { replace, keepBoth, skip }

/// Names from [names] that are already in [existing] (case-insensitive when
/// the target is Windows).
List<int> funtiClashes(
    List<String> names, Iterable<String> existing, bool windows) {
  String norm(String n) => windows ? n.toLowerCase() : n;
  final taken = {for (final e in existing) norm(e)};
  return [
    for (var i = 0; i < names.length; i++)
      if (taken.contains(norm(names[i]))) i
  ];
}

/// The plan for sending [names] into a folder with [existing] names:
/// for each item to send, its index in [names] and its name in the target.
/// Skipped items are left out; with keepBoth a clash gets "name (2).ext",
/// also avoiding names given to earlier items of the same batch.
List<(int, String)> funtiPlanSend(List<String> names, Iterable<String> existing,
    bool windows, FuntiConflict? choice) {
  String norm(String n) => windows ? n.toLowerCase() : n;
  final taken = {for (final e in existing) norm(e)};
  final clashes = funtiClashes(names, existing, windows).toSet();
  final plan = <(int, String)>[];
  for (var i = 0; i < names.length; i++) {
    var name = names[i];
    if (clashes.contains(i)) {
      if (choice == FuntiConflict.skip) continue;
      if (choice == FuntiConflict.keepBoth) {
        name = funtiFreeName(name, (n) => taken.contains(norm(n)));
      }
    }
    taken.add(norm(name));
    plan.add((i, name));
  }
  return plan;
}

/// Contents of the Windows "downloaded from the Internet" mark
/// (`file:Zone.Identifier`, zone 3), as a browser writes it.
const funtiZoneIdentifier = '[ZoneTransfer]\r\nZoneId=3\r\n';
