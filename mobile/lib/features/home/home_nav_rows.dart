import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';

/// The Activity and Search rows pinned under the channel list's community
/// header on every surface, like the desktop sidebar's primary menu. The wide
/// shell selects a main-pane surface with them and shows which is selected;
/// the phone pushes the page.
class HomeNavRows extends StatelessWidget {
  /// Creates the rows.
  const HomeNavRows({
    required this.hasUnreadInbox,
    required this.onActivity,
    required this.onSearch,
    this.activitySelected = false,
    this.searchSelected = false,
    super.key,
  });

  /// Whether the Activity inbox has unread items (a dot on its row).
  final bool hasUnreadInbox;

  /// Opens the Activity inbox.
  final VoidCallback onActivity;

  /// Opens Search.
  final VoidCallback onSearch;

  /// Whether the Activity inbox is the surface on show (wide shell only).
  final bool activitySelected;

  /// Whether Search is the surface on show (wide shell only).
  final bool searchSelected;

  /// Height of one row.
  static const double rowHeight = 36;

  /// Total height the list header reserves for these rows.
  static const double height = rowHeight * 2 + Grid.xxs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Grid.twelve, 0, Grid.twelve, Grid.xxs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HomeNavRow(
            key: const ValueKey('home-nav-activity'),
            icon: LucideIcons.inbox300,
            selectedIcon: LucideIcons.inbox500,
            label: 'Activity',
            selected: activitySelected,
            showUnreadDot: hasUnreadInbox,
            onTap: onActivity,
          ),
          _HomeNavRow(
            key: const ValueKey('home-nav-search'),
            icon: LucideIcons.search300,
            selectedIcon: LucideIcons.search500,
            label: 'Search',
            selected: searchSelected,
            showUnreadDot: false,
            onTap: onSearch,
          ),
        ],
      ),
    );
  }
}

class _HomeNavRow extends StatelessWidget {
  const _HomeNavRow({
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
        height: HomeNavRows.rowHeight,
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
                      key: const ValueKey('home-nav-activity-unread-dot'),
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
