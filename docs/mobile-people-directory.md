# The Flutter app's people directory (fork feature)

Every place the phone, the iPad and the macOS client list *people to pick*
— the New message sheet, Add members, the community invite page, mention
autocomplete and the people rows of Search — reads the relay's kind:0
profiles through the HTTP bridge. Two things about that listing are easy to
get wrong, and both were: it was cut to one page, and it showed identities
the relay had already retired. This document records how the fork handles
each and where the seams are.

## Every page, or an error — never a silent slice

`queryRelayPages` (`lib/shared/relay/relay_paging.dart`) walks the bridge's
1-based `page` extension until a page comes back short, a page adds nothing
new (a relay that ignores `page` would repeat page 1 forever), or the
20-page ceiling is reached (`relayDirectoryMaxPages`; 20 × 50 is the relay's
advertised NIP-11 `max_limit`). The relay orders the directory by
`created_at DESC, id ASC` and the client re-sorts by label, so a single
50-row page would have rendered "the fifty most recently updated profiles,
alphabetized" with nothing to tell the reader it was cut. The same helper
serves the prefix search behind the sheet's search field
(`NostrFilters.searchUsers`), which the bridge pages the same way.

A failed page fails the listing. The sheet shows its error state with
Retry instead of the pages fetched so far: returning a partial list would
turn a transport failure into an authoritative "everyone".

Callers: `relayDirectoryUsersProvider` and `relayDirectorySearchProvider`
(`lib/features/channels/channel_management_provider.dart`), and
`communityInviteDirectoryProvider` / `communityInviteDirectorySearchProvider`
(`lib/features/invites/invite_create_provider.dart`).

## Archived identities (NIP-IA)

`docs/nips/NIP-IA.md`: when an owner retires an agent key, rotates a key or
removes a spammer, the relay records the pubkey in `archived_identities` and
signs a replaceable `kind:13535` snapshot listing every archived pubkey as a
`p` tag. Archiving is a visibility hint, not a ban — history stays, and the
identity can still connect. Desktop honours the snapshot through
`features/identity-archive/hooks.ts`; before this change the Flutter app had
no notion of it, so every retired duplicate ("Pollen" five times, "Honey"
four times) stayed in the New message sheet.

`lib/shared/identity_archive/identity_archive.dart`:

- `archivedIdentitiesProvider` queries `kind:13535` with `authors` set to the
  relay's NIP-11 `self` pubkey (`relaySelfPubkeyProvider`, read from the same
  NIP-11 document as the app-content door), keeps the newest snapshot, and
  verifies its id and Schnorr signature before trusting the `p` tags. It is
  **fail-open**: empty while the session has never connected, while `self`
  is unknown, when the query fails, or when the snapshot does not verify.
  Hiding nobody is the safe failure; hiding everyone on a cold start is not.
  It refetches on reconnect, on a relay change, and whenever a people picker
  opens (`_newDirectMessageFromHeader`, the Add members row), the way
  desktop's query refetches on mount.
- `ArchivedIdentityFilter` is the single predicate. It is **self-exempt by
  construction**: the signed-in user is never hidden from their own client,
  even when archived, because NIP-IA's anti-shadowban property needs the
  archived user to see it and ask for self-unarchive. Callers never
  re-implement the exemption.
- `archivedIdentityFilterProvider` resolves the filter for the active relay.
  Pickers `await` its future so the first render is already folded;
  already-visible lists read `.value` and get `ArchivedIdentityFilter.none`
  until the snapshot lands.

Where it applies (matching desktop's call sites that have a mobile
counterpart):

| Surface | Seam | Behaviour |
|---|---|---|
| New message sheet, Add members sheet | `relayDirectoryUsersProvider`, `relayDirectorySearchProvider` | hidden |
| Community invite page | `communityInviteDirectoryProvider`, `communityInviteDirectorySearchProvider` | hidden |
| Mention autocomplete | `mentionCandidatesProvider` (every source: channel members, agent teams, relay agents, global search) | hidden |
| Search page people rows | `ChannelActions.searchUsers` | hidden |
| Channel members sheet | `MembersSheet` | folded into an "Archived · N" group below People and Agents (`members-sheet-archived`); archived wins over bot, so a retired agent key folds there rather than under Agents |

Not applied, deliberately: DM rows, message authors, reactions, threads and
activity keep the archived author — NIP-IA forbids rewriting history — so an
old conversation with a retired key stays in the sidebar under its name.
Desktop's other call sites (agent management rows, persona sharing, project
assignees and reviewers) have no mobile counterpart. Not built yet: the
"Archived on this relay" flair on a profile, live `kind:8002`/`8003` deltas
(the snapshot is re-read on reconnect and picker open instead), and
archiving from the phone.

## Tests

- `test/shared/relay/relay_paging_test.dart` — page walk, short page, exact
  multiple, repeated page, ceiling, failed page.
- `test/shared/identity_archive/identity_archive_test.dart` — snapshot
  parsing against a real relay-signed event (wrong signer, tampered
  signature, newest wins), the self-exempt predicate, and the provider's
  fail-open paths.
- `channel_management_provider_test.dart`, `invite_create_provider_test.dart`
  — the production providers against a fake bridge that serves pages and the
  snapshot: paging, a failed page, hiding, and listing everyone when the
  snapshot cannot be read.
- `channels_page_test.dart` ("new message sheet and the relay archive") —
  the sheet itself, keyed on `new-dm-person-<pubkey>`, through the real
  providers: an archived person is absent, everyone is present while the
  snapshot is unavailable, and a 70-profile directory fetches two pages.
- `channel_detail_page_test.dart` ("members sheet folds relay-archived
  members"), `compose_bar_test.dart` ("hides a relay-archived agent from
  mention suggestions", "keeps suggesting everyone while the archive
  snapshot loads").
