# How the Flutter app renders a mention (fork feature)

A Buzz message can address someone two ways, and the SDK resolves both
(`crates/buzz-sdk/src/mentions.rs`): by display name, `@Alice`, and by key,
the NIP-27 URI `nostr:npub1…`. Agents prefer the key form because a key is
unambiguous — two people can carry the same display name, but only one holds
a given key — and the relay stores the same `p` tag either way.

Only the reading side was missing. Until this change the phone, the iPad and
the macOS client drew `@Alice` as a chip and left the keyed form as 63
characters of raw bech32, so a message that correctly addressed the reader
looked like noise. Both forms now render the same chip.

## What renders

`MessageContent` claims two inline patterns
(`lib/features/channels/message_content/nostr_mention.dart`):

| In the body | Chip label |
|---|---|
| `nostr:npub1…` | the mentioned person's display name |
| `nostr:nprofile1…` | the same — relay hints are not part of the identity |
| either, with no profile in scope | the compact npub, `npub1x6q…dr3f` |
| either, naming an agent | the bot chip, as `@agent` mentions get — read from the profile's NIP-OA owner, so a `p`-tagged and an untagged mention of one agent look alike |

## The key names the person, not the tag

A keyed mention carries its key in the body, so the chip resolves the name from
that key: the `p`-tag map first, then the shared profile cache
(`userCacheProvider`), then the compact npub.

That lookup only **reads** the cache. The keys come out of message text, which
nobody vouches for — a code block full of valid keys renders no chip at all —
so letting a body decide how many profiles to fetch would hand it an unbounded,
repeating work budget (a key nobody has is never cached, so every scroll back
asks again). Everything that knows a key is real already requests it: the
`p`-tag map, the message author, the member roster. At most 50 keys per body
are looked up, matching the SDK's `MENTION_CAP`.

It has to work that way, because often no `p` tag names the person at all.
This client does not scan a composed body for `nostr:` URIs when it builds
tags — only `@name` chips from the composer become tags — and a sender is
never tagged for mentioning themselves (`messageMentionPubkeys` seeds its seen
set with the sender). The owner hit exactly that: his own key, pasted into a
message, drew a compact npub while the same key from an agent drew his name,
because the agent's message came through the SDK, which does extract the URI.

**The composer does not tag the people a keyed mention names, so a
`nostr:npub…` typed in this client renders correctly and notifies nobody.**
Before this chip existed the reader saw 63 characters of bech32 and read it as
a pasted key; now it is shaped exactly like a delivered `@mention`, which is a
signal the message does not earn. Closing it means extracting the URIs into `p`
tags on send, the way the SDK does — a change to who gets notified and pushed,
so it is a separate decision, not a detail.

Where the surface wires `onMentionTap` — a channel bubble, a thread reply, a
forum post — the chip opens the key it names even with no profile loaded: the
compact npub tells the reader which key was addressed and the profile sheet
tells them who that is. Search hits, activity rows and forum cards pass no
callback, so their chips only label. Name resolution reuses the `p`-tag map
every mention already uses (`mentionNamesWithDirectoryLabels`), so a keyed
mention and an `@name` mention of the same person agree.

The chip carries the tap and the label as one screen-reader stop (`Open
profile of …`); its own `@` and text are excluded so the pill does not
announce itself a second time.

`npub` is matched as a fixed window — `npub1` plus exactly 58 bech32
characters — because that is the window the relay's own extractor reads and
tags (`extract_nostr_uris`), trailing text included. Reading the same window
keeps the chip and the `p` tag describing the same message. That extractor
understands **only** `npub`, so an `nprofile` renders here but is not what the
relay tags; agents address people with `npub`.

## What does not render, on purpose

- **Event references.** `nostr:note1…`, `nostr:nevent1…` and `nostr:naddr1…`
  name an event, not a person. Drawing one as a person would be a lie, and
  showing it properly needs an event lookup this surface does not do, so they
  keep their source text.
- **Code, as far as this renderer understands code.** A fenced block never
  reaches the inline pass. A single-backtick span is claimed at its backtick,
  which starts before the URI inside it. gpt_markdown does not read a
  CommonMark ``double-backtick`` span as code at all, so the pattern refuses a
  URI with a backtick on either side — otherwise the key became a chip sitting
  between two visible backticks.

  **A four-space indented code block is not protected**: `IndentMd` strips the
  indent and feeds the rest back to the inline pass, so a URI there becomes a
  chip. Every chip in this client behaves that way — `@name` and `#channel`
  included — and the SDK's `strip_code_regions` does not strip indented code
  either, so the sender's `p` tag and the reader's chip still agree. Recorded
  as known, not fixed.

- **A link label.** `[nostr:npub1…](https://example.com)` keeps its source
  text: a label renders inside the link's own `WidgetSpan` and a second one
  nested in it does not paint on iOS, which is why `ATagMd` and `AutolinkMd`
  exclude the scope and why this component does too. The fork's older chips
  (`@name`, `#channel`, custom emoji) do not yet exclude it — a separate,
  pre-existing defect.
- **A payload that does not decode**, including an `nsec` envelope: a secret
  key is not an identity, and `nostrProfileUriPubkey`
  (`lib/shared/utils/string_utils.dart`) returns null for every prefix but
  `npub` and `nprofile`. Undecodable text falls back to itself.

## Seams

- `nostrProfileUriPubkey` is the only decoder; it is pure and unit-tested
  against the NIP-19 specification's own vectors
  (`test/shared/utils/string_utils_test.dart`).
- The chip body is `_MentionPill`, shared with `@name` mentions, so the two
  forms cannot drift apart visually.
- The match pattern is deliberately loose about case. gpt_markdown compiles
  every inline component into one alternation and drops case sensitivity as
  soon as a single component is case-insensitive — which the `@`/`#` pill
  patterns are — so the guarantee comes from decoding, not from the character
  class.

## Verify on a device

1. An agent mentions you with `nostr:npub…` → the chip carries your name, not
   bech32; tapping it opens your profile.
2. A message naming a key with no profile in the community → the compact npub
   chip, and tapping it opens that profile sheet.
2b. Your own key, pasted into a message you send → your name, not a npub.
3. The same URI inside `` ` ` ``, inside ``` `` ``` and inside a fenced block
   → still the URI.
4. `nostr:note1…` in a body → still the URI.
5. VoiceOver over a chip → one stop, "Open profile of …", activating it opens
   the profile.

Surfaces to check: a channel bubble, a thread reply and a forum post — they
all render through `MessageContent`. A push banner does not: `previewBody` in
`BuzzPushNotificationResolver.swift` strips Markdown but not `nostr:` URIs, so
a keyed mention still reads as bech32 in the banner — which is where the owner
first saw it. Reminder previews store the raw body and are unchanged too.
