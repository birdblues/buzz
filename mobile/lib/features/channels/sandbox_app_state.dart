import 'dart:convert';

/// View state handed from one version of a sandboxed app to the next
/// (`docs/sandboxed-apps.md`, "New versions").
///
/// The running app returns it through a host-owned script; the host parses
/// it, keeps only the fields below within bounds, re-serialises it and hands
/// the base64 of that to the new document. The app's runtime applies the
/// same schema again before using it. Anything that does not fit is dropped
/// whole — a partially applied state is worse than the default view.
///
/// Both caps are re-applied here whatever the page returned: the page can
/// redefine its own bridge object, so its promises count for nothing.
const sandboxAppStateMaxBytes = 64 * 1024;
const sandboxAppStateMaxListLength = 500;
const sandboxAppStateMaxIdLength = 200;

/// Canonical JSON for [decoded], or null when it is not a valid app state.
String? canonicalSandboxAppState(Object? decoded) {
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['v'] != 1) return null;
  final view = decoded['view'];
  if (view != 'grid' && view != 'compressed') return null;
  final t = decoded['t'];
  if (t is! num || !t.isFinite || t < 0 || t > 1e6 || t != t.floor()) {
    return null;
  }
  final collapsed = _stringList(decoded['collapsed']);
  final sel = _stringList(decoded['sel']);
  if (collapsed == null || sel == null) return null;
  final includeFeedback = decoded['includeFeedback'];
  if (includeFeedback != null && includeFeedback is! bool) return null;
  final cam = decoded['cam'];
  if (cam is! Map<String, dynamic>) return null;
  final zoom = cam['zoom'];
  final pan = cam['pan'];
  if (!_finiteIn(zoom, 0.01, 100) || pan is! Map<String, dynamic>) return null;
  final panX = pan['x'];
  final panY = pan['y'];
  if (!_finiteIn(panX, -1e6, 1e6) || !_finiteIn(panY, -1e6, 1e6)) return null;
  final moved = <String, Map<String, num>>{};
  final movedRaw = decoded['moved'];
  if (movedRaw != null) {
    if (movedRaw is! Map<String, dynamic>) return null;
    if (movedRaw.length > sandboxAppStateMaxListLength) return null;
    for (final entry in movedRaw.entries) {
      final id = entry.key;
      final point = entry.value;
      if (id.isEmpty || id.length > sandboxAppStateMaxIdLength) return null;
      if (point is! Map<String, dynamic>) return null;
      final x = point['x'];
      final y = point['y'];
      if (!_finiteIn(x, -1e5, 1e5) || !_finiteIn(y, -1e5, 1e5)) return null;
      moved[id] = {'x': x as num, 'y': y as num};
    }
  }
  final canonical = jsonEncode({
    'v': 1,
    'view': view,
    't': t.toInt(),
    'collapsed': collapsed,
    'sel': sel,
    'includeFeedback': includeFeedback == true,
    'cam': {
      'zoom': zoom,
      'pan': {'x': panX, 'y': panY},
    },
    'moved': moved,
  });
  if (utf8.encode(canonical).length > sandboxAppStateMaxBytes) return null;
  return canonical;
}

/// What `runJavaScriptReturningResult` gave back for the export script,
/// turned into the base64 the new document's `_importB64` takes — or null
/// when the page returned anything but a JSON string of a valid state.
String? sandboxAppStateToBase64(Object? result) {
  if (result is! String) return null;
  if (utf8.encode(result).length > sandboxAppStateMaxBytes) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(result);
  } on FormatException {
    return null;
  }
  final canonical = canonicalSandboxAppState(decoded);
  if (canonical == null) return null;
  return base64Encode(utf8.encode(canonical));
}

List<String>? _stringList(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) return null;
  if (raw.length > sandboxAppStateMaxListLength) return null;
  final out = <String>[];
  for (final item in raw) {
    if (item is! String ||
        item.isEmpty ||
        item.length > sandboxAppStateMaxIdLength) {
      return null;
    }
    out.add(item);
  }
  return out;
}

bool _finiteIn(Object? value, num min, num max) =>
    value is num && value.isFinite && value >= min && value <= max;
