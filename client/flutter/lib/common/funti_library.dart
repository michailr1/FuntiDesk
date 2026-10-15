// Account lists contain addresses and labels, never peer configuration or trust.
import 'dart:convert';
import '../common.dart';
import '../models/platform_model.dart';

Future<Map<String, dynamic>> funtiLibraryStatus() async {
  if (!isWindows) return {};
  final raw = await bind.mainFuntiAccount(action: 'status', payload: '{}');
  return Map<String, dynamic>.from(jsonDecode(raw));
}

Future<List<String>> getFuntiFavoriteIds() async {
  final state = await funtiLibraryStatus();
  if (state['library_enabled'] != true) return (await bind.mainGetFav()).toList();
  final rows = state['data']?['library']?['favorites'] as List? ?? [];
  return rows.map((row) => row['funti_id'] as String).toList();
}

Future<bool> changeFuntiFavorites({List<String> add = const [], List<String> remove = const []}) async {
  final state = await funtiLibraryStatus();
  if (state['library_enabled'] != true) {
    final rows = (await bind.mainGetFav()).toList();
    rows.removeWhere(remove.contains);
    for (final id in add) { if (!rows.contains(id)) rows.add(id); }
    await bind.mainStoreFav(favs: rows);
    return true;
  }
  final library = state['data']?['library'];
  if (library is! Map) return false;
  final rows = (library['favorites'] as List).map((row) => Map<String, dynamic>.from(row)).toList();
  rows.removeWhere((row) => remove.contains(row['funti_id']));
  for (final id in add) {
    if (!rows.any((row) => row['funti_id'] == id)) rows.add({'funti_id': id, 'name': ''});
  }
  final raw = await bind.mainFuntiAccount(action: 'favorites_set', payload: jsonEncode({
    'account_id': state['account_id'], 'revision': library['revision'], 'favorites': rows,
  }));
  final reply = Map<String, dynamic>.from(jsonDecode(raw));
  if (reply['error'] != null) {
    showToast(translate(reply['error'] as String));
    await bind.mainLoadFavPeers();
    return false;
  }
  await bind.mainLoadFavPeers();
  return true;
}
