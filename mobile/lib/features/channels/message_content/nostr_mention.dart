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

  /// The one scan both sides share, so a chip and a `p` tag never disagree
  /// about who a message addresses (`nostr_uri_mentions.dart`).
  @override
  RegExp get exp => nostrProfileUriPattern;

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

/// How a keyed mention should be drawn for each of [pubkeys] that [known] does
/// not already name: the display name, and whether the key belongs to an agent
/// so it gets the bot chip rather than an `@`.
///
/// A keyed mention carries its key in the body, so it can name the person even
/// when no `p` tag does, and often none does: this client does not scan a
/// composed body for `nostr:` URIs when it builds tags, and a sender is never
/// tagged for mentioning themselves (`messageMentionPubkeys`). Without this the
/// chip fell back to a compact npub for people whose profile was right there,
/// and drew an agent as an ordinary person.
///
/// It only reads. The keys come from message text, which nobody vouches for:
/// a code block full of valid keys renders no chip at all, and requesting a
/// profile per key would let a body decide how much the client fetches, with
/// the misses repeating every time the row scrolls back. Every key that
/// matters is already requested by something that knows it is real — the p-tag
/// map, the message author, the member roster — so this reads what they filled
/// in and falls back to the compact npub otherwise.
({Map<String, String> names, Set<String> agents}) keyedMentionIdentities(
  WidgetRef ref,
  List<String> pubkeys,
  Map<String, String> known,
) {
  final names = <String, String>{};
  final agents = <String>{};
  for (final pubkey in pubkeys) {
    if (known.containsKey(pubkey)) continue;
    final profile = ref.watch(
      userCacheProvider.select((cache) => cache[pubkey]),
    );
    if (profile == null) continue;
    final name = profile.displayName;
    if (name != null && name.trim().isNotEmpty) names[pubkey] = name;
    // The same rule the p-tag path uses (`agentPubkeysWithProfileOwners`): a
    // profile carrying a NIP-OA owner is an agent, so the two mention forms
    // draw one identity the same way.
    if (profile.ownerPubkey != null) agents.add(pubkey);
  }
  return (names: names, agents: agents);
}
