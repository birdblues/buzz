part of '../wide_home_shell.dart';

/// The card pinned to the bottom of the wide shell's sidebar, after the
/// desktop app's: the signed-in profile (avatar with presence dot and display
/// name) over the active community (its icon, or 🐝 when it has none, and its
/// name). Tapping the card opens Settings; tapping the community row opens
/// the community switcher.
///
/// On a phone the same two entry points live in the channel list header, so
/// the wide shell asks [ChannelsPage] to hide its header avatar and hosts
/// this card instead.
class _SidebarProfileCard extends ConsumerWidget {
  const _SidebarProfileCard({required this.settingsPageBuilder});

  final WidgetBuilder settingsPageBuilder;

  /// Fixed height so the sidebar's floating launcher can sit above it.
  static const double height = 60;

  static const double _avatarSize = 32;
  static const double _communityIconSize = 14;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final community = ref.watch(activeCommunityProvider).value;
    final displayName = profile?.displayName?.trim();
    final name = displayName != null && displayName.isNotEmpty
        ? displayName
        : profile == null
        ? ''
        : shortPubkey(profile.pubkey);
    final communityName = community?.name.trim() ?? '';
    final communityLabel = communityName.isEmpty
        ? 'No community'
        : communityName;

    void openSettings() {
      unawaited(HapticFeedback.lightImpact());
      Navigator.of(context).push(
        settingsPageRoute(
          builder: settingsPageBuilder,
          onTransitionProgress: (_) {},
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Grid.xxs,
          Grid.quarter,
          Grid.xxs,
          Grid.xxs,
        ),
        child: Semantics(
          button: true,
          label: name.isEmpty
              ? 'Open settings'
              : 'Open settings for $name, community $communityLabel',
          excludeSemantics: true,
          onTap: openSettings,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.md),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('wide-sidebar-profile-card'),
              onTap: openSettings,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Grid.xxs,
                  vertical: Grid.quarter,
                ),
                child: Row(
                  children: [
                    const ProfileAvatar(size: _avatarSize),
                    const SizedBox(width: Grid.xs),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            key: const ValueKey(
                              'wide-sidebar-profile-card-name',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          _CommunityRow(
                            community: community,
                            label: communityLabel,
                            onTap: () => showCommunitySwitcher(context, ref),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The community line of the card: its relay icon (🐝 without one) and its
/// name; a tap opens the switcher rather than Settings.
class _CommunityRow extends ConsumerWidget {
  const _CommunityRow({
    required this.community,
    required this.label,
    required this.onTap,
  });

  final Community? community;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relayUrl = community?.relayUrl;
    final iconUrl = relayUrl == null
        ? null
        : ref.watch(communityIconProvider(relayUrl)).value;
    final secondary = context.textTheme.labelSmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Semantics(
      button: true,
      label: 'Switch community, currently $label',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: const ValueKey('wide-sidebar-profile-card-community'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: _SidebarProfileCard._communityIconSize,
              child: iconUrl == null
                  ? Center(
                      child: Text(
                        '🐝',
                        style: secondary?.copyWith(fontSize: 11),
                      ),
                    )
                  : AvatarImage(
                      imageUrl: iconUrl,
                      radius: _SidebarProfileCard._communityIconSize / 2,
                      backgroundColor: context.colors.primaryContainer,
                      fallback: const SizedBox.shrink(),
                    ),
            ),
            const SizedBox(width: Grid.quarter),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
