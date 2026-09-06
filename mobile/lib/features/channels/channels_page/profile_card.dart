part of '../channels_page.dart';

/// The signed-in profile as the sidebar's footer, after the desktop app's
/// `SidebarProfileCard`: the avatar with its presence dot and the display
/// name. Tapping it opens Settings. The community is named in the header at
/// the top of the sidebar, so the card does not repeat it.
///
/// Shared by the wide shell's sidebar and the phone's home screen, so every
/// layout opens Settings from the same place.
class SidebarProfileCard extends ConsumerWidget {
  /// Creates the card.
  const SidebarProfileCard({
    required this.settingsPageBuilder,
    required this.onSettingsTransitionProgress,
    super.key,
  });

  /// Builds the Settings page the card opens.
  final WidgetBuilder settingsPageBuilder;

  /// Reports the Settings route's transition progress; see [ChannelsPage].
  final ValueChanged<double> onSettingsTransitionProgress;

  /// Diameter of the avatar.
  static const double avatarSize = 32;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final displayName = profile?.displayName?.trim();
    final name = displayName != null && displayName.isNotEmpty
        ? displayName
        : profile == null
        ? ''
        : shortPubkey(profile.pubkey);

    void openSettings() {
      unawaited(HapticFeedback.lightImpact());
      Navigator.of(context).push(
        settingsPageRoute(
          builder: settingsPageBuilder,
          onTransitionProgress: onSettingsTransitionProgress,
        ),
      );
    }

    return Semantics(
      button: true,
      label: name.isEmpty ? 'Open settings' : 'Open settings for $name',
      excludeSemantics: true,
      onTap: openSettings,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('sidebar-profile-card'),
          onTap: openSettings,
          child: Padding(
            padding: const EdgeInsets.all(Grid.xxs),
            child: Row(
              children: [
                const ProfileAvatar(size: avatarSize),
                const SizedBox(width: Grid.twelve),
                Expanded(
                  child: Text(
                    name,
                    key: const ValueKey('sidebar-profile-card-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
