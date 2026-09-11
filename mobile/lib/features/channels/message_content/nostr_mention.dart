part of '../message_content.dart';

/// Inline NIP-27 profile references — `nostr:npub1…` and `nostr:nprofile1…`.
///
/// Both mention forms are part of the contract: the SDK resolves `@name` and
/// `nostr:` URIs alike (`crates/buzz-sdk/src/mentions.rs`) and agents prefer
/// the key form because a key is unambiguous where two people can share a
/// display name. Only the reader's side was missing, so a keyed mention
/// arrived as 63 characters of bech32 instead of the person it addressed.
///
/// Only the two profile forms are claimed. `note`/`nevent`/`naddr` name
/// events rather than people and would need an event lookup to render, so
/// they keep the plain-text treatment they have today.
class _NostrMentionMd extends InlineMd {
  final Map<String, String> mentionNames;
  final Set<String> agentMentionPubkeys;
  final void Function(String pubkey)? onMentionTap;

  _NostrMentionMd({
    required this.mentionNames,
    required this.agentMentionPubkeys,
    this.onMentionTap,
  });

  /// A link label is rendered inside the link's own `WidgetSpan`, and a second
  /// one nested in it does not paint on iOS — the reason `ATagMd` and
  /// `AutolinkMd` exclude the scope. A keyed mention used as a link label
  /// stays source text rather than becoming an invisible chip.
  @override
  Set<MarkdownScope> get scopes => MarkdownComponent.allScopesExceptLinkLabel;

  /// `npub` is fixed width — `npub1` plus exactly 58 bech32 characters — and
  /// that window is what the relay's own extractor tags
  /// (`extract_nostr_uris`, which reads the same 58 characters and ignores
  /// what follows). Matching the same window means the chip names whoever the
  /// message actually tagged, even when the key runs straight into other text.
  /// `nprofile` carries relay hints and has no fixed length, so it is matched
  /// loosely and validated by decoding.
  ///
  /// The bech32 body is matched case-insensitively because the combined
  /// pattern gpt_markdown compiles is case-insensitive as soon as one
  /// component is (`_buildPrefixPattern` builds every pill that way). The
  /// guarantee comes from decoding, not from the character class.
  ///
  /// Backticks on either side keep a URI out of the chip: gpt_markdown reads
  /// only single-backtick spans as inline code, so without this a key inside
  /// a CommonMark ``double-backtick`` span would render as a chip between two
  /// visible backticks.
  static final RegExp _pattern = RegExp(
    r'(?<![\w./`-])nostr:(?:npub1[a-z0-9]{58}|nprofile1[a-z0-9]+)(?!`)',
    caseSensitive: false,
    multiLine: true,
  );

  @override
  RegExp get exp => _pattern;

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final raw = exp.firstMatch(text.trim())?.group(0);
    final pubkey = raw == null ? null : nostrProfileUriPubkey(raw);
    if (pubkey == null) {
      return TextSpan(text: text, style: config.style);
    }

    // A keyed mention always knows who it names, so the chip is tappable even
    // when no profile has arrived: the compact npub is the label, and opening
    // the profile is how the reader finds out who that is.
    final label = mentionNames[pubkey] ?? shortPubkey(pubkey);
    final pill = _MentionPill(
      label: label,
      isAgent: agentMentionPubkeys.contains(pubkey),
      textStyle: config.style,
    );
    final onTap = onMentionTap;

    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: onTap == null
          ? Semantics(
              label: 'Mention of $label',
              excludeSemantics: true,
              child: pill,
            )
          : Semantics(
              button: true,
              label: 'Open profile of $label',
              onTap: () => onTap(pubkey),
              excludeSemantics: true,
              child: GestureDetector(onTap: () => onTap(pubkey), child: pill),
            ),
    );
  }
}
