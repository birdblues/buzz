# Community name on the relay (fork feature)

Upstream Buzz keeps a community's display name on each desktop install (the
label typed when the community was added) and its icon on the relay
(`communities.icon`, set through the kind:9033 workspace-profile command and
served as the NIP-11 `icon`). The phone and the Mac client had nothing to read
a name from, so they showed one derived from the relay host — `192.168.1.99`
for a LAN relay.

The fork stores the name next to the icon.

## Contract

- **Storage:** `communities.name TEXT` (migration `0045_community_name.sql`).
- **Write:** the existing kind:9033 command gains a `["name", value]` tag.
  The relay trims the value, refuses control characters (so it is always one
  line), caps it at 64 characters, and treats an empty value as "clear".
  Authorization is upstream's for 9033: relay admin/owner, or any
  authenticated sender on an open relay that has no steward row.
- **Tag independence:** a 9033 that carries only `name` leaves the icon
  untouched, and one that carries only `icon` (what the upstream desktop
  sends) leaves the name untouched. Upstream's rule that a 9033 *without any*
  `icon` tag clears the icon is preserved for events that carry no `name`
  either. See `plan_workspace_profile_update` in
  `crates/buzz-relay/src/handlers/relay_admin.rs`.
- **Read:** the NIP-11 document's `name` field carries the community name;
  without one it stays the stock `Buzz Relay`.
- **Clients:** the Flutter app (iPhone, iPad, macOS client) reads NIP-11
  `name` (`lib/shared/community/community_relay_name_provider.dart`), ignores
  the stock `Buzz Relay`, and adopts any other value into the stored
  community record, so the sidebar, the switcher, push notification
  snapshots and offline launches all show it. The upstream desktop keeps its
  local label and ignores this field.

## Setting it

```sh
buzz community set-name "슈퍼지구"   # relay admin/owner identity
buzz community profile             # {"name": "...", "icon": ...}
buzz community set-name --clear
```

The CLI mirrors the relay's validation so a bad name fails before signing.
The change is visible to clients on their next NIP-11 read: the app re-reads
it when the community header is built, so relaunching (or switching
communities) is enough.

## Not covered

Per-device overrides (a client cannot choose its own name for a community),
localisation, and a desktop editor — the upstream desktop would need a
`name` field in its Edit-community dialog to set this without the CLI.
