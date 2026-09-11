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
| either, naming a known agent | the bot chip, as `@agent` mentions get |

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
