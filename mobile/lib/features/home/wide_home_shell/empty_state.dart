part of '../wide_home_shell.dart';

/// Main pane content when no channel is selected. Renders its own app bar so
/// the sidebar toggle stays reachable.
class _EmptyMainPane extends StatelessWidget {
  const _EmptyMainPane();

  @override
  Widget build(BuildContext context) {
    return FrostedScaffold(
      appBar: const FrostedAppBar(showBottomDivider: false),
      body: Center(
        child: Column(
          key: const ValueKey('wide-main-empty'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.messagesSquare,
              size: 40,
              color: context.colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: Grid.xs),
            Text(
              'Select a channel',
              style: context.textTheme.titleMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
