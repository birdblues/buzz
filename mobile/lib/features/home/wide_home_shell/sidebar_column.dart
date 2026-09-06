part of '../wide_home_shell.dart';

/// The collapsible sidebar: the channel list page with the shell's navigation
/// rows pinned under its community header, and the profile card as its footer.
class _SidebarColumn extends ConsumerWidget {
  const _SidebarColumn({
    required this.settingsPageBuilder,
    required this.hasUnreadInbox,
  });

  final WidgetBuilder settingsPageBuilder;
  final bool hasUnreadInbox;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(wideSidebarCollapsedProvider);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final mediaQuery = MediaQuery.of(context);

    return ClipRect(
      child: AnimatedContainer(
        duration: reducedMotion ? Duration.zero : _kSidebarMotionDuration,
        curve: _kSidebarMotionCurve,
        width: collapsed ? 0 : kWideSidebarWidth,
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: kWideSidebarWidth,
          maxWidth: kWideSidebarWidth,
          child: ExcludeSemantics(
            excluding: collapsed,
            child: IgnorePointer(
              ignoring: collapsed,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: context.colors.outlineVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  ),
                ),
                // The list page and its sheets size themselves from the
                // window width; give them the column's width instead.
                child: MediaQuery(
                  data: mediaQuery.copyWith(
                    size: Size(kWideSidebarWidth, mediaQuery.size.height),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: ChannelsPage(
                          settingsPageBuilder: settingsPageBuilder,
                          onSettingsTransitionProgress: (_) {},
                          pinnedHeader: _SidebarNavRows(
                            hasUnreadInbox: hasUnreadInbox,
                          ),
                          pinnedHeaderHeight: _SidebarNavRows.height,
                          // Settings lives in the profile card below,
                          // like the desktop app.
                          showProfileAvatar: false,
                        ),
                      ),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: context.colors.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          Grid.xxs,
                          Grid.xxs,
                          Grid.xxs,
                          Grid.xxs + mediaQuery.padding.bottom,
                        ),
                        child: SidebarProfileCard(
                          settingsPageBuilder: settingsPageBuilder,
                          onSettingsTransitionProgress: (_) {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
