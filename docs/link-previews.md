# Link previews

How Buzz shows a card for an external web link in a message, and what each
client does with it. The contract is set by the relay and the desktop app
(upstream "rich link previews" work); this page records it in one place and
adds the mobile reader.

## Contract: the sender previews, readers render

Recipients never contact the linked site. The **sender's** client fetches the
page once while composing, uploads the page image and favicon to the relay as
ordinary image blobs, and signs the result into the message as tags:

```
["link-preview","snapshot","1",
  canonicalUrl,   // https, no credentials, no fragment; must appear in content
  title,          // ≤ 300 bytes, no control characters
  siteName,       // ≤ 100 bytes
  description,    // ≤ 1000 bytes, newlines allowed
  imageUrl, imageSha256,      // relay /media/<sha>.<jpg|png|gif|webp>, or both ""
  faviconUrl, faviconSha256]  // same rule
["link-preview","none"]       // sender removed every preview; no snapshots allowed
```

Up to 8 snapshot tags per message, one per canonical URL. The relay rejects
anything else at ingest (`crates/buzz-relay/src/handlers/ingest.rs`,
`validate_link_preview_tags`), and every reader re-checks the same rules
before rendering, so a tag the relay would refuse never draws a card.

Why this shape: it keeps a reader's IP and identity away from the sites other
people link to, and it makes the preview part of the signed message, so what
everyone sees is what the sender saw.

| Surface | Authoring (sender) | Rendering (reader) |
|---|---|---|
| Desktop | `useComposerLinkPreviews.tsx` fetches metadata natively (SSRF-checked), uploads image/favicon blobs, emits the tags; the composer can remove previews (`none`) | `linkPreviewSnapshot.ts` parses, `link-preview-attachment.tsx` draws (compact by default, rich as a preference) |
| Mobile | Not yet (phase 2) | `message_content/link_preview_snapshot.dart` parses, `link_preview_card.dart` draws the compact card |
| CLI | Not yet | n/a |

## Mobile reader (phase 1)

Files: `mobile/lib/features/channels/message_content/link_preview_snapshot.dart`
(parser), `link_preview_card.dart` (card), wiring in `message_content.dart`.

Rules, in the order they are applied:

1. **Suppressed or no relay**: `["link-preview","none"]` on the event, or no
   active relay base URL, renders nothing.
2. **Cropped surfaces render nothing** — any `MessageContent` with `maxLines`
   (search hits, inbox rows, profile status). Full message bodies in channels,
   threads, forum posts and replies render cards.
3. **Tag shape**: exactly 11 fields, version `"1"`, at most 8 accepted per
   message, duplicates by canonical URL dropped.
4. **Canonical URL**: https, host present, no userinfo, no `#`. It must appear
   verbatim in the body outside code (fenced, inline, indented) and outside
   markdown image syntax, matching what desktop would preview. Cards are
   ordered by where the link appears in the body.
5. **Text limits**: title ≤ 300, site name ≤ 100, description ≤ 1000 UTF-8
   bytes; no control characters, except newlines in the description.
6. **Media pairs**: image and favicon are each either both empty or a relay
   blob whose path is `/media/<sha256>.<jpg|png|gif|webp>` with the hash
   matching the tag's sha256, on the active relay's scheme and authority (port
   80/443 normalised), with no query, fragment, or credentials. The blob loads
   through `MediaImage`, which attaches the Blossom read token only for relay
   URLs, so a failed check can never leak a token or fetch from a third party.

The card is the desktop **compact** presentation: a 104×64 thumbnail on the
left when there is an image (favicon, then a broken-image glyph, as fallbacks),
hostname (favicon + host without `www.`), title (falls back to the hostname),
description collapsed to one paragraph. Host, title and description are one
line each with an ellipsis, as on desktop, so the text block stays the height
of the thumbnail. Without an image it is the quote-style variant with a rule
on the left. The whole card is one button; tapping opens the canonical URL in
the system browser. Nothing on the card is interactive beyond that, and nothing
in it comes from anywhere but the signed tag and relay blobs.

Not in phase 1: the rich (large image) style and the style preference, the
"remove preview for everyone" control, tweet-specific layout, and mobile
authoring. Buzz-native `buzz://` entity links stay chips, as on desktop.

### Verify on a device

1. From desktop, post in a channel the iPad can see a message with a public
   https link that has Open Graph metadata (a GitHub repository page works).
   Wait for the composer preview to appear before sending, so the snapshot tag
   is attached. Inspect with `buzz messages get` if in doubt: the event should
   carry one `link-preview snapshot 1 …` tag.
2. On the iPad: the message shows a compact card below the body with the site
   favicon and host, the title, a description, and a thumbnail. Tap it: Safari
   opens the link. Nothing is fetched from the linked host by the app (the
   sandbox listeners from `docs/sandboxed-apps.md` are not needed; the check
   is that the thumbnail URL is the relay's `/media/…`).
3. Post the same link and remove the preview in the desktop composer before
   sending. The iPad shows the plain link and no card.
4. Search for the message and open the inbox: the preview rows show no card.
5. Post a message whose link sits only inside a code span. Desktop attaches no
   snapshot; the iPad shows no card. (If a client ever did attach one, the
   iPad would still show no card, because the URL is not visible in the body.)
6. Switch the iPad between light and dark: the card follows the theme;
   thumbnails are the same blob in both.

Widget tests: `mobile/test/features/channels/link_preview_snapshot_test.dart`,
`message_content_link_preview_test.dart`.
