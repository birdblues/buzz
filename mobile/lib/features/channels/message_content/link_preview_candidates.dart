import 'link_preview_snapshot.dart';

/// The links in a draft that a sender previews: https URLs in the visible
/// body (not inside code or image syntax), in order of appearance, without
/// fragments, at most [linkPreviewMaxSnapshots], each exactly as it appears
/// in the body so the relay's "canonical URL is in the content" rule holds.
///
/// Mirrors desktop `extractSupportedLinkPreviews` for the generic-link case.
/// Buzz-native links (`buzz://`, relay git clone URLs) are entity chips on
/// every client and never snapshot.
final _httpsUrl = RegExp('https://[^\\s<>"\'\\]]+');
final _trailingPunctuation = RegExp(r'[.,!?;:]+$');
final _relayGitPath = RegExp(r'/git/[0-9a-f]{64}/');
const _bracketPairs = [(')', '('), (']', '['), ('}', '{')];

/// Strips trailing sentence punctuation and closing brackets that have no
/// opener inside the URL, so `(see https://x.y/z)` yields `https://x.y/z`.
String trimLinkPreviewCandidate(String candidate) {
  var value = candidate.replaceFirst(_trailingPunctuation, '');
  var changed = true;
  while (changed) {
    changed = false;
    for (final (close, open) in _bracketPairs) {
      if (value.endsWith(close) && _count(value, close) > _count(value, open)) {
        value = value.substring(0, value.length - 1);
        changed = true;
      }
    }
  }
  return value;
}

int _count(String value, String char) {
  var count = 0;
  for (final rune in value.runes) {
    if (rune == char.codeUnitAt(0)) count += 1;
  }
  return count;
}

List<String> extractLinkPreviewCandidates(
  String content, {
  int max = linkPreviewMaxSnapshots,
}) {
  final visible = maskHiddenLinkPreviewContent(content);
  final seen = <String>{};
  final candidates = <String>[];
  for (final match in _httpsUrl.allMatches(visible)) {
    final trimmed = trimLinkPreviewCandidate(match[0]!);
    final hash = trimmed.indexOf('#');
    final canonical = hash < 0 ? trimmed : trimmed.substring(0, hash);
    if (!isValidLinkPreviewCanonicalUrl(canonical)) continue;
    if (_relayGitPath.hasMatch(Uri.parse(canonical).path)) continue;
    if (!seen.add(canonical)) continue;
    candidates.add(canonical);
    if (candidates.length >= max) break;
  }
  return candidates;
}
