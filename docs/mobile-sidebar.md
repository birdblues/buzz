# The Flutter app's sidebar (fork feature)

The phone, the iPad and the macOS client (`docs/client-desktop.md`) share
one sidebar structure, modelled on the upstream desktop sidebar
(`desktop/src/features/sidebar/ui/AppSidebar.tsx`). Upstream mobile has a
different phone layout (a floating tab bar and a floating quick-actions
button); this fork replaces it so the three surfaces look and work alike.

```
 슈  Community name        header: tap opens the community switcher
 ▤  Activity   ●          navigation rows: the wide shell selects a pane,
 🔍 Search                 the phone pushes the page (with Back)
 # Channels   +  ⋮  ⌄     + creates a channel
   # general
   # design            [Join]   an open channel you have not joined
 💬 Forums    +  ⋮  ⌄     + creates a forum
 💬 DMs       +  ⋮  ⌄     + starts a direct message
 C  Display name           footer card: tap opens Settings
```

## Navigation rows and the phone

`HomeNavRows` (`lib/features/home/home_nav_rows.dart`) sits pinned under the
community header on every surface (`home-nav-activity`, `home-nav-search`,
the unread dot `home-nav-activity-unread-dot`). The wide shell selects the
Activity or Search surface of its main pane and highlights the selected row;
the phone pushes `ActivityPage` or `SearchPage` as a full-screen route with
a Back button, and Search opens with its field focused (`autofocus`). A
pushed page starts fresh each time: there is no retained tab state and no
"tap the tab again to scroll to the top".

The phone's `HomePage` is therefore the wide shell's sidebar at full width:
the channel list, the rows, and the profile card as the footer, with the
bottom safe area under the card. Upstream's floating tab bar (Home /
Activity / Search), its content transitions, its clearance inset and its
footer fade are gone; only the composer still paints that fade behind
itself.

## Section headers

Each built-in section header carries, after its label, a `+`
(`section-add-<Label>`), the `⋮` options menu and the collapse chevron, in
the desktop's order. The `+` opens the section's create sheet — a stream
channel, a forum, or a new message — and opens what was created. The
floating quick-actions button that used to hold these three actions is gone,
and so is its "Browse channels" sheet. Starred and user-defined sections have
no `+`.

Where this differs from the desktop on purpose: the desktop's Channels `+`
opens a "Browse channels" dialog that searches, joins and creates in one
place. Here the sidebar itself does the browsing, so `+` only creates.

## Open channels you have not joined

`channelsProvider` already carries every open, non-archived channel the
relay lists (`Channel.canJoin`), not only memberships; the list used to
filter them out. Now the Channels and Forums sections list them after the
joined rows, A–Z regardless of the section's sort mode, dimmed, each with a
`Join` button (`unjoined-channel-<id>`, `join-channel-<id>`). Tapping the row
opens the channel read-only, as on the desktop; `Join` sends the kind 9021
join, and on success opens the channel as a member. A failure is reported
under the row and the button is re-enabled.

These rows carry no read state: they are never seeded as read and never
count as unread, and they collapse with their section. At most 100 are
listed per section; a trailing row counts the rest
(`channels-directory-more`). Private channels, DMs and archived channels are
never listed unless you are a member.

The directory loads with the list (once per relay and identity, again after
a reconnect) instead of on demand, and a pull-to-refresh re-reads it so
channels created since launch appear. A mouse wheel never pulls, so the
Channels and Forums `⋮` menus also carry "Refresh channels" for the macOS
client. While it loads or after it fails, the
Channels section ends in a status row (`channels-directory-loading`,
`channels-directory-retry`).

Forums have their own section so a joined forum is reachable from the
sidebar; upstream mobile listed neither joined nor open forums there.

## Footer card

`SidebarProfileCard` (`channels_page/profile_card.dart`): the avatar with
its presence dot and the display name; tapping it opens Settings. The
community is named in the header above, so the card does not repeat it, and
the channel list header carries no Settings avatar on any surface: the card
is the one way into Settings.
