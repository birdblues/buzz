import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/layout/layout_mode.dart';
import 'app_webview_page.dart';
import 'sandbox_bridge.dart';
import 'wide_shell/wide_shell_provider.dart';

/// Runs a sandboxed app from its card (`docs/sandboxed-apps.md`, "Beside
/// the thread").
///
/// Compact: the app takes the whole screen, pushed on the root navigator
/// (a push inside a wide-shell pane's nested navigator aborts — its compose
/// bar's overlay portal is re-activated during the pane's layout pass).
///
/// Wide, with a message in scope: the app opens beside the message's
/// thread so the reader can keep instructing the agent from the thread
/// composer. The thread is opened first when the auxiliary pane does not
/// show it yet ([openThread], from the row that owns the card); the app
/// pane is mounted on the next frame so it never races the pane's remount.
void openSandboxApp(
  BuildContext context,
  WidgetRef ref, {
  required String sha256,
  required String filename,
  String? sharedBy,
  SandboxBridgeTarget? bridge,
  VoidCallback? openThread,
}) {
  if (!LayoutModeScope.isWide(context) || bridge == null) {
    Navigator.of(context, rootNavigator: true).push(
      AppWebViewPage.route(
        sha256: sha256,
        filename: filename,
        sharedBy: sharedBy,
        bridge: bridge,
      ),
    );
    return;
  }

  final root = bridge.threadRootId ?? bridge.messageId;
  // Selections from the app land in the thread composer beside it, whose
  // draft is keyed by the thread root.
  final target = bridge.copyWith(threadHeadId: bridge.threadHeadId ?? root);
  final shell = ref.read(wideShellProvider.notifier);
  final pane = WideAppPane(
    channelId: target.channelId,
    messageId: target.messageId,
    sha256: sha256,
    filename: filename,
    sharedBy: sharedBy,
    bridge: target,
  );

  bool threadShowing() => switch (ref.read(wideShellProvider).aux) {
    WideAuxThread(:final threadHead) =>
      (threadHead.rootId ?? threadHead.id) == root,
    WideAuxForumThread(:final postEventId) => postEventId == root,
    null => false,
  };
  if (threadShowing() || openThread == null) {
    shell.openAppPane(pane);
    return;
  }
  openThread();
  // Mounted only if the thread really is beside it now: had the open been
  // refused or overtaken, the app would cover a pane that is not its own.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (threadShowing()) shell.openAppPane(pane);
  });
}
