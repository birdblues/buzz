part of '../wide_home_shell.dart';

/// The right column of an app split: a header naming the app and the
/// version it shows, and the running app itself.
///
/// Hide keeps the app running (the card's dot stays lit and the layer
/// slides back in on the next Run); Close ends it.
class _AppPaneColumn extends ConsumerWidget {
  const _AppPaneColumn({super.key, required this.pane});

  final WideAppPane pane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(wideShellProvider.notifier);
    final sessions = ref.read(sandboxSessionsProvider.notifier);
    final sessionKey = sandboxSessionKeyFor(pane.sha256, pane.bridge);
    final view = ref.watch(
      sandboxSessionsProvider.select((s) => s[sessionKey]),
    );
    final updated = sandboxRevisionLabel(context, view?.revisionAt);
    final divider = context.colors.outlineVariant.withValues(alpha: 0.5);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(left: BorderSide(color: divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: Grid.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pane.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.titleSmall,
                      ),
                      Text(
                        [
                          if (pane.sharedBy case final by?) 'Shared by $by',
                          ?updated,
                          'Sandbox · no network',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.labelSmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (view?.isUpdating == true)
                  const Padding(
                    key: ValueKey('wide-app-updating'),
                    padding: EdgeInsets.symmetric(horizontal: Grid.xxs),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                IconButton(
                  key: const ValueKey('wide-app-hide'),
                  onPressed: notifier.hideAppPane,
                  color: context.colors.primary,
                  tooltip: 'Hide app (keeps running)',
                  icon: const Icon(LucideIcons.panelRightClose, size: 22),
                ),
                IconButton(
                  key: const ValueKey('wide-app-close'),
                  onPressed: () {
                    sessions.terminate(sessionKey);
                    notifier.hideAppPane();
                  },
                  color: context.colors.primary,
                  tooltip: 'Close app',
                  icon: const Icon(LucideIcons.x, size: 22),
                ),
                const SizedBox(width: Grid.xxs),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: divider),
          Expanded(
            child: AppSandboxBody(sha256: pane.sha256, bridge: pane.bridge),
          ),
        ],
      ),
    );
  }
}
