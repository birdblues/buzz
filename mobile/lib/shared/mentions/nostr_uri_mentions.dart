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
/// duplicates, code regions excluded, at most [nostrUriMentionCap] of them.
///
/// Quoting a key must not address its owner, so code is removed first — the
/// same reason the SDK runs `strip_code_regions` before its own scan.
List<String> nostrUriMentionPubkeys(String content) {
  if (content.length < 'nostr:npub1'.length) return const [];
  final pubkeys = <String>{};
  for (final match in nostrProfileUriPattern.allMatches(
    stripCodeRegions(content),
  )) {
    final pubkey = nostrProfileUriPubkey(match.group(0)!);
    if (pubkey != null) pubkeys.add(pubkey);
    if (pubkeys.length == nostrUriMentionCap) break;
  }
  return pubkeys.toList(growable: false);
}

/// [content] with fenced blocks and inline code spans replaced by a space, so
/// a scan over the result cannot see anything that was written as code.
///
/// A port of the SDK's `strip_code_regions` (`crates/buzz-sdk/src/mentions.rs`)
/// — deliberately the same shape, including what it does not cover: an indented
/// code block is not code here, and neither is a CommonMark double-backtick
/// span (its two ticks read as one empty inline span). Sender and relay must
/// agree on who a message tags; matching CommonMark instead would split them.
String stripCodeRegions(String content) {
  final out = StringBuffer();
  var i = 0;
  while (i < content.length) {
    if (content.startsWith('```', i) && _onlyIndentBefore(content, i)) {
      out.write(' ');
      i = _fencedBlockEnd(content, i);
      continue;
    }
    if (content[i] == '`') {
      final afterTick = i + 1;
      final close = afterTick < content.length
          ? content.indexOf('`', afterTick)
          : -1;
      if (close >= 0 && !content.substring(afterTick, close).contains('\n')) {
        out.write(' ');
        i = close + 1;
        continue;
      }
    }
    out.write(content[i]);
    i++;
  }
  return out.toString();
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
