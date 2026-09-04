part of '../wide_home_shell.dart';

/// Activity and Search rows pinned under the sidebar's community header.
class _SidebarNavRows extends ConsumerWidget {
  const _SidebarNavRows({required this.hasUnreadInbox});

  final bool hasUnreadInbox;

  static const double rowHeight = 36;

  /// Total height reserved by the sidebar header for these rows.
  static const double height = rowHeight * 2 + Grid.xxs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surface = ref.watch(wideShellProvider.select((s) => s.surface));
    final notifier = ref.read(wideShellProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Grid.twelve, 0, Grid.twelve, Grid.xxs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SidebarNavRow(
            key: const ValueKey('wide-nav-activity'),
            icon: LucideIcons.inbox300,
            selectedIcon: LucideIcons.inbox500,
            label: 'Activity',
            selected: surface == WideSurface.inbox,
            showUnreadDot: hasUnreadInbox,
            onTap: notifier.showInbox,
          ),
          _SidebarNavRow(
            key: const ValueKey('wide-nav-search'),
            icon: LucideIcons.search300,
            selectedIcon: LucideIcons.search500,
            label: 'Search',
            selected: surface == WideSurface.search,
            showUnreadDot: false,
            onTap: notifier.showSearch,
          ),
        ],
      ),
    );
  }
}

class _SidebarNavRow extends StatelessWidget {
  const _SidebarNavRow({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.showUnreadDot,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool showUnreadDot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = navigationPrimaryForeground(context);
    return Semantics(
      button: true,
      selected: selected,
      label: showUnreadDot ? '$label, unread' : label,
      excludeSemantics: true,
      child: SizedBox(
        height: _SidebarNavRows.rowHeight,
        child: Material(
          color: selected
              ? context.colors.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Grid.xxs),
              child: Row(
                children: [
                  Icon(
                    selected ? selectedIcon : icon,
                    size: 18,
                    color: foreground,
                  ),
                  const SizedBox(width: Grid.xxs),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: contentListTitleTextStyle.copyWith(
                        color: foreground,
                        fontWeight: selected || showUnreadDot
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (showUnreadDot)
                    Container(
                      key: const ValueKey('wide-nav-activity-unread-dot'),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: context.colors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
