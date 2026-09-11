import '../utils/string_utils.dart';

/// NIP-27 profile references in message bodies — `nostr:npub1…` and
/// `nostr:nprofile1…`.
///
/// Both the reader and the sender work from this one scan, so a chip and a
/// `p` tag never disagree about who a message addresses.

/// Matches a `nostr:` profile reference.
///
/// `npub` is a fixed width — `npub1` plus exactly 58 bech32 characters — and
/// that window is what the relay's own extractor reads (`extract_nostr_uris`
/// in `crates/buzz-sdk/src/mentions.rs`), trailing text ignored. `nprofile`
/// carries relay hints and has no fixed length, so it is matched loosely and
/// validated by decoding.
///
/// The body is matched case-insensitively — the combined pattern gpt_markdown
/// compiles is case-insensitive as soon as one inline component is, and the
/// `@`/`#` pill patterns are — so the guarantee comes from decoding, not from
/// the character class. Backticks on either side keep a URI out: gpt_markdown
/// reads only single-backtick spans as inline code, so without this a key in a
/// CommonMark ``double-backtick`` span would render as a chip between two
/// visible backticks.
final RegExp nostrProfileUriPattern = RegExp(
  r'(?<![\w./`-])nostr:(?:npub1[a-z0-9]{58}|nprofile1[a-z0-9]+)(?!`)',
  caseSensitive: false,
  multiLine: true,
);

/// The most people one message may address, mirroring the SDK's `MENTION_CAP`.
///
/// A body carrying more keys than this is not a wall of mentions — it is a key
/// dump, and neither tagging nor naming the rest is worth the work.
const int nostrUriMentionCap = 50;

/// Every profile key [content] addresses by NIP-27 URI: first-seen order, no
/// duplicates, at most [nostrUriMentionCap] of them.
///
/// **This is exactly the set the reader sees as mention chips.** The renderer
/// claims the same pattern and skips the same places, so a message never tags
/// someone it does not visibly address — nobody gets a notification for a
/// mention that is invisible to every reader, including its author.
///
/// Skipped: code, because quoting a key must not summon its owner, and link or
/// image syntax, because a key there renders as the link's label or its alt
/// text rather than as a mention.
List<String> nostrUriMentionPubkeys(String content) {
  // The scheme is lowercase (see [nostrProfileUriPubkey]), so this cheap test
  // is exact, and it keeps the scans below off every message without a key.
  if (!content.contains('nostr:')) return const [];
  final skip = _unaddressableRanges(content);
  final pubkeys = <String>{};
  for (final match in nostrProfileUriPattern.allMatches(content)) {
    if (skip.any((r) => match.start >= r.start && match.start < r.end)) {
      continue;
    }
    final pubkey = nostrProfileUriPubkey(match.group(0)!);
    if (pubkey != null) pubkeys.add(pubkey);
    if (pubkeys.length == nostrUriMentionCap) break;
  }
  return pubkeys.toList(growable: false);
}

/// Link and image syntax — `[label](destination)` and its `!` form.
///
/// Mirrors what `ATagMd` and `ImageMd` claim in gpt_markdown, which is why a
/// key inside one never becomes a chip: the label renders inside the link's own
/// widget (where a nested one does not paint on iOS) and the destination
/// renders as a URL.
final RegExp _markdownLinkPattern = RegExp(
  r'!?\[.*?\]\([^\s]*\)',
  dotAll: true,
);

/// Where in [content] a `nostr:` URI is not a mention: code regions and link
/// or image syntax.
List<({int start, int end})> _unaddressableRanges(String content) => [
  ..._codeRegions(content),
  for (final match in _markdownLinkPattern.allMatches(content))
    (start: match.start, end: match.end),
];

/// [content] with fenced blocks and inline code spans replaced by a space.
///
/// The readable form of [_codeRegions], and the surface its agreement with the
/// relay is checked through: this is a port of the SDK's `strip_code_regions`
/// (`crates/buzz-sdk/src/mentions.rs`), deliberately the same shape — including
/// what it does not cover. An indented code block is not code here, and neither
/// is a CommonMark double-backtick span, whose two ticks read as one empty
/// inline span. Sender and relay must agree on what counts as code; matching
/// CommonMark instead would split them.
String stripCodeRegions(String content) {
  final out = StringBuffer();
  var next = 0;
  for (final region in _codeRegions(content)) {
    out.write(content.substring(next, region.start));
    out.write(' ');
    next = region.end;
  }
  out.write(content.substring(next));
  return out.toString();
}

/// Fenced blocks and inline code spans in [content], in order, never
/// overlapping.
List<({int start, int end})> _codeRegions(String content) {
  final regions = <({int start, int end})>[];
  var i = 0;
  while (i < content.length) {
    if (content.startsWith('```', i) && _onlyIndentBefore(content, i)) {
      final end = _fencedBlockEnd(content, i);
      regions.add((start: i, end: end));
      i = end;
      continue;
    }
    if (content[i] == '`') {
      final afterTick = i + 1;
      final close = afterTick < content.length
          ? content.indexOf('`', afterTick)
          : -1;
      if (close >= 0 && !content.substring(afterTick, close).contains('\n')) {
        regions.add((start: i, end: close + 1));
        i = close + 1;
        continue;
      }
    }
    i++;
  }
  return regions;
}

/// Whether everything between the start of [index]'s line and [index] is
/// whitespace — a fence only opens or closes at the head of its own line.
bool _onlyIndentBefore(String content, int index) {
  final lineStart = content.lastIndexOf('\n', index == 0 ? 0 : index - 1) + 1;
  return content.substring(lineStart, index).trim().isEmpty;
}

/// The index just past a fenced block opening at [start]: after the closing
/// fence's line, or the end of [content] when the fence is never closed.
int _fencedBlockEnd(String content, int start) {
  var search = _lineEnd(content, start + 3);
  while (search < content.length) {
    final close = content.indexOf('```', search);
    if (close < 0) return content.length;
    if (_onlyIndentBefore(content, close)) return _lineEnd(content, close + 3);
    search = close + 3;
  }
  return content.length;
}

/// The index just past the newline that ends the line containing [from], or
/// the end of [content] when that line is the last one.
int _lineEnd(String content, int from) {
  if (from >= content.length) return content.length;
  final newline = content.indexOf('\n', from);
  return newline < 0 ? content.length : newline + 1;
}
