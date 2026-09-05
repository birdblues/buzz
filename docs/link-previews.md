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
| Mobile | `ComposerLinkPreviewsController` (`features/channels/composer_link_previews.dart`) drives `shared/link_preview/` — fetch, sanitize, upload — and hands the tags to the send; the compose bar shows a card per link and one "send without previews" control | `message_content/link_preview_snapshot.dart` parses, `link_preview_card.dart` draws the compact card |
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
on the left. The whole card is one button; tapping hands the canonical URL to
the OS (Safari, or the app registered for that link). Nothing on the card is interactive beyond that, and nothing
in it comes from anywhere but the signed tag and relay blobs.

Not in phase 1: the rich (large image) style and the style preference, the
"remove preview for everyone" control, and tweet-specific layout. Buzz-native
`buzz://` entity links stay chips, as on desktop.

## Mobile authoring (phase 2)

The mobile composer authors snapshots the way the desktop composer does:
the device fetches each linked page once, re-hosts its image and favicon on
the relay, and signs the result into the event. Every compose bar takes part
(channels, threads, forum posts and replies), because they share one widget.

Files: `mobile/lib/shared/link_preview/` — `link_preview_fetcher.dart`
(network, guards), `link_preview_metadata.dart` (Open Graph / Twitter /
`<title>` extraction), `link_preview_youtube.dart` (oEmbed for video URLs,
which serve a consent wall to anonymous fetchers), `link_preview_image.dart`
(decode, bound, re-encode) — and `mobile/lib/features/channels/`
`composer_link_previews.dart` (the per-draft controller),
`message_content/link_preview_candidates.dart` (which links qualify),
`compose_bar/link_preview_strip.dart` (the cards).

What happens as you type:

1. **Candidates.** After 350 ms of quiet, the https links in the visible
   body (not inside code or image syntax) are taken in order, fragments
   dropped, trailing punctuation and unbalanced brackets trimmed, at most 8,
   each exactly as it appears so the relay's "URL is in the content" rule
   holds. `http://`, `buzz://` and relay git clone links never qualify.
2. **Fetch, guarded.** Same rules as the desktop native command:
   https only, no credentials, default port; the host must resolve to global
   unicast addresses — loopback, RFC 1918, link-local, CGNAT, documentation,
   multicast, ULA, 6to4 anycast, and IPv4-mapped / NAT64 forms of those are
   refused — and the socket is pinned to the checked addresses, so a
   rebinding DNS answer cannot redirect the connect. The pin is an
   `HttpClient.connectionFactory` that opens `SecureSocket.startConnect` on
   the looked-up `InternetAddress`: with a factory set dart:io does not
   negotiate TLS itself, and a looked-up address carries the name it was
   resolved from, so the handshake verifies the certificate and sends SNI
   for the URL's host while the bytes go to the checked address
   (`link_preview_pinned_client_test.dart` proves both against a local
   https server). Redirects are
   followed by hand, at most 3, each hop re-checked; 4 s per request, 10 s
   total; 256 KiB of HTML, 2 MiB per image, 64 KiB of oEmbed.
3. **Sanitize.** An image must declare `image/jpeg|png|webp`, its bytes must
   match, it must not be animated (APNG `acTL`, WebP `ANIM`/VP8X flag), and
   it must fit 4096 px a side and 16 MP. It is then decoded off the UI
   isolate, EXIF orientation baked in, downscaled to 1200 px on the long
   side, and re-encoded — JPEG at quality 82, or PNG for a favicon with alpha.
   The bytes the relay stores are ours, never the site's.
4. **Upload and tag.** Image and favicon go through the ordinary Blossom
   upload (`MediaUploadService.uploadBytes`), and the tag is built from the
   title, the site name (hostname when the page has none), the description,
   and the two blob pairs. A failed upload yields a text-only tag; a failed
   fetch yields no tag and the link sends bare.
5. **Cards.** Each candidate shows a compact card above the editor (skeleton
   while loading, "No preview available" when the page yields none). One
   control, "Send without link previews", hides them all and sends
   `["link-preview","none"]`; the choice clears once the draft has no links.
6. **Send.** The send takes the ready tags for the links still in the body,
   waiting up to 6 s for ones in flight, then goes out — a preview never
   fails or holds a message. A snapshot is cached for 5 minutes per URL, so a
   link that leaves and re-enters the draft is instant, and the cache is
   dropped on a community switch (blob URLs belong to one relay).

Differences from desktop, by choice: no transient-failure retry with
backoff (one attempt per link per draft), no separate metadata cache across
composers, and cards are one size.

### Verify on a device

1. Type a public https link into a channel composer and wait a moment: a
   card with the page title and site appears above the editor, with the
   page image when it has one. Send. Desktop and the iPad render the card
   from the tag; `buzz messages get` shows one `link-preview snapshot 1 …`
   tag whose image URL is the relay's `/media/…`.
2. Type a YouTube link: the card shows the video title and channel; the
   thumbnail comes from `i.ytimg.com` through the relay.
3. Tap the × on the strip and send: no card on any client, and the event
   carries `["link-preview","none"]`.
4. Type `https://192.168.1.99:3000/` or `https://localhost/`: no card ever
   appears and nothing hits the relay's request log for a preview fetch.
5. Delete the link before the fetch finishes, then send: the event carries no
   preview tag.
6. Send immediately after pasting a slow page: the send waits briefly, then
   goes out (with the tag if the page answered in time, without it if not).

Widget tests: `mobile/test/shared/link_preview/*_test.dart`,
`mobile/test/features/channels/composer_link_previews_test.dart`,
`link_preview_candidates_test.dart`, and the `link previews` group in
`compose_bar_test.dart`.

### Verify on a device

1. From desktop, post in a channel the iPad can see a message with a public
   https link that has Open Graph metadata (a GitHub repository page works).
   Wait for the composer preview to appear before sending, so the snapshot tag
   is attached. Inspect with `buzz messages get` if in doubt: the event should
   carry one `link-preview snapshot 1 …` tag.
2. On the iPad: the message shows a compact card below the body with the site
   favicon and host, the title, a description, and a thumbnail. Tap it: the
   link leaves the app — Safari, or the app that owns the link (a `youtu.be`
   link opens YouTube through its universal link). Nothing is fetched from the
   linked host by the app (the sandbox listeners from `docs/sandboxed-apps.md`
   are not needed; the check is that the thumbnail URL is the relay's
   `/media/…`).
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
