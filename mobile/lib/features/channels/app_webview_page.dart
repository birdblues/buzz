import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import 'app_sandbox_body.dart';
import 'sandbox_bridge.dart';
import 'sandbox_session.dart';

export 'sandbox_session.dart'
    show
        appSandboxDocumentUri,
        decideAppNavigation,
        sandboxHardeningProbeProvider;

/// Full-screen page for one sandboxed HTML app (`docs/sandboxed-apps.md`).
///
/// The app itself lives in [sandboxSessionsProvider], not here: this page
/// attaches to a session while it is on screen and detaches when it goes.
/// **Back keeps the app running** — the next page for the same app
/// re-attaches the same WebView with its state intact — and the **Close**
/// action in the bar ends it. The session applies the sandbox rules (fresh
/// blob-scoped token, stamped CSP, `about:blank` with an opaque origin,
/// navigation locked to one load, native WebRTC removal) and the expiry
/// rules for backed-out apps.
///
/// The one JavaScript channel, `buzzHost`, exists only when [bridge] names
/// the message the app was shared in. It carries the selection bridge
/// (`sandbox_bridge.dart`): a validated `{ kind, ref, text }` from the app
/// becomes a draft in that message's composer, the page pops, and the user
/// decides what to send. A session keyed to that message also follows its
/// edits: a new version of the app swaps in with the view state carried
/// over (`sandbox_revision.dart`).
///
/// Wide windows show the app beside its thread instead (`sandbox_open.dart`,
/// `wide_home_shell/app_pane.dart`); this page is the compact layout's.
class AppWebViewPage extends ConsumerWidget {
  final String sha256;
  final String filename;
  final String? sharedBy;
  final SandboxBridgeTarget? bridge;

  const AppWebViewPage({
    super.key,
    required this.sha256,
    required this.filename,
    this.sharedBy,
    this.bridge,
  });

  /// Slides in from the right on the root navigator: the app takes the
  /// whole screen on every layout.
  static Route<void> route({
    required String sha256,
    required String filename,
    String? sharedBy,
    SandboxBridgeTarget? bridge,
  }) {
    return CupertinoPageRoute<void>(
      title: filename,
      builder: (_) => AppWebViewPage(
        sha256: sha256,
        filename: filename,
        sharedBy: sharedBy,
        bridge: bridge,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final sessionKey = sandboxSessionKeyFor(sha256, bridge);
    final sessions = ref.read(sandboxSessionsProvider.notifier);

    // The bridge turned a selection into a draft: leave the reader on the
    // composer. The app stays alive behind Back. (The wide shell's app pane
    // does not pop — the composer is already beside the app there.)
    ref.listen<int?>(
      sandboxSessionsProvider.select((s) => s[sessionKey]?.prefillSeq),
      (previous, next) {
        if (previous != null && next != null && next > previous) {
          Navigator.of(context).maybePop();
        }
      },
    );

    final revisionAt = ref.watch(
      sandboxSessionsProvider.select((s) => s[sessionKey]?.revisionAt),
    );
    final subtitle = [
      if (sharedBy case final sharedBy?) 'Shared by $sharedBy',
      ?sandboxRevisionLabel(context, revisionAt),
      'Runs in a sandbox · no network · Back keeps it running',
    ].join(' · ');

    return FrostedScaffold(
      backgroundColor: colors.surface,
      appBar: FrostedAppBar(
        title: Text(filename, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('app-sandbox-close'),
            tooltip: 'Close app',
            icon: const Icon(LucideIcons.x),
            onPressed: () {
              sessions.terminate(sessionKey);
              Navigator.of(context).maybePop();
            },
          ),
        ],
        bottom: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Grid.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
        bottomHeight: Grid.gutter,
      ),
      // The frosted bar floats over the body; keep the app below it so the
      // page never shows through a translucent bar.
      body: Padding(
        padding: EdgeInsets.only(
          top: frostedAppBarHeight(context, bottomHeight: Grid.gutter),
        ),
        child: AppSandboxBody(sha256: sha256, bridge: bridge),
      ),
    );
  }
}
