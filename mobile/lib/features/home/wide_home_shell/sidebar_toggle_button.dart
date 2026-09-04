part of '../wide_home_shell.dart';

/// Shows or hides the sidebar. Injected into the main pane's app bar through
/// [PaneScope.headerLeading].
class _SidebarToggleButton extends ConsumerWidget {
  const _SidebarToggleButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(wideSidebarCollapsedProvider);
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        key: const ValueKey('wide-sidebar-toggle'),
        onPressed: ref.read(wideSidebarCollapsedProvider.notifier).toggle,
        color: context.colors.primary,
        tooltip: collapsed ? 'Show sidebar' : 'Hide sidebar',
        icon: Icon(
          collapsed ? LucideIcons.panelLeftOpen : LucideIcons.panelLeftClose,
        ),
      ),
    );
  }
}
