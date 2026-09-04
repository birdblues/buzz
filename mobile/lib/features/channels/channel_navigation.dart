import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/layout/layout_mode.dart';
import '../../shared/layout/pane_scope.dart';
import '../forum/forum_thread_page.dart';
import 'channel.dart';
import 'channel_detail_page.dart';
import 'thread_detail_page.dart';
import 'timeline_message.dart';
import 'wide_shell/wide_shell_provider.dart';

/// The single seam deciding whether a channel, thread, or forum post opens as
/// a pushed full-screen route (compact layout) or in a wide-shell pane.
///
/// Every production caller goes through these helpers; a test guards against
/// direct `ChannelDetailPage`/`ThreadDetailPage`/`ForumThreadPage` pushes.

/// Opens [channel]'s timeline.
Future<void> openChannelDetail(
  BuildContext context, {
  required Channel channel,
  String? initialMessageId,
  String? initialThreadRootId,
  InitialThreadRouteBehavior initialThreadRouteBehavior =
      InitialThreadRouteBehavior.push,
}) async {
  if (LayoutModeScope.isWide(context)) {
    _dismissRootRoutes(context);
    _wideShell(context).selectChannel(
      channel,
      initialMessageId: initialMessageId,
      initialThreadRootId: initialThreadRootId,
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChannelDetailPage(
        channel: channel,
        initialMessageId: initialMessageId,
        initialThreadRootId: initialThreadRootId,
        initialThreadRouteBehavior: initialThreadRouteBehavior,
      ),
    ),
  );
}

/// Opens the thread rooted at [threadHead].
///
/// In the wide layout a thread opened from the auxiliary pane stacks inside
/// that pane (nested threads keep a back button); from anywhere else it
/// replaces the auxiliary pane's content. [replaceCurrentRoute] only applies
/// to the compact layout, where it swaps the current route for the thread.
Future<void> openThreadDetail(
  BuildContext context, {
  required TimelineMessage threadHead,
  required List<TimelineMessage> allMessages,
  required String channelId,
  required String? currentPubkey,
  required bool isMember,
  required bool isArchived,
  String? initialMessageId,
  bool replaceCurrentRoute = false,
}) async {
  final wide = LayoutModeScope.isWide(context);
  if (wide && PaneScope.maybeOf(context)?.kind != PaneKind.aux) {
    _dismissRootRoutes(context);
    _wideShell(context).openAux(
      WideAuxThread(
        threadHead: threadHead,
        allMessages: allMessages,
        channelId: channelId,
        initialMessageId: initialMessageId,
      ),
    );
    return;
  }
  final route = MaterialPageRoute<void>(
    builder: (_) => ThreadDetailPage(
      threadHead: threadHead,
      allMessages: allMessages,
      channelId: channelId,
      currentPubkey: currentPubkey,
      isMember: isMember,
      isArchived: isArchived,
      initialMessageId: initialMessageId,
    ),
  );
  final navigator = Navigator.of(context);
  if (replaceCurrentRoute && !wide) {
    await navigator.pushReplacement(route);
  } else {
    await navigator.push(route);
  }
}

/// Opens the forum post [postEventId] in [channel].
Future<void> openForumThread(
  BuildContext context, {
  required Channel channel,
  required String postEventId,
  required String? currentPubkey,
}) async {
  if (LayoutModeScope.isWide(context)) {
    _dismissRootRoutes(context);
    _wideShell(context).openAux(
      WideAuxForumThread(channelId: channel.id, postEventId: postEventId),
      channel: channel,
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ForumThreadPage(
        channelId: channel.id,
        postEventId: postEventId,
        currentPubkey: currentPubkey,
        isMember: channel.isMember,
        isArchived: channel.isArchived,
      ),
    ),
  );
}

/// Leaves the channel page: pops the route in the compact layout, or clears
/// the pane in the wide layout.
void closeChannelDetail(BuildContext context) {
  final pane = PaneScope.maybeOf(context);
  if (pane != null) {
    pane.close();
    return;
  }
  Navigator.of(context).pop();
}

WideShellNotifier _wideShell(BuildContext context) => ProviderScope.containerOf(
  context,
  listen: false,
).read(wideShellProvider.notifier);

/// A pane-state change is invisible while a root route (Settings, a huddle
/// call, a sheet) covers the shell, so bring the shell back first. In the
/// compact layout the new page is pushed on top instead.
void _dismissRootRoutes(BuildContext context) {
  final root = Navigator.of(context, rootNavigator: true);
  if (root.canPop()) root.popUntil((route) => route.isFirst);
}
