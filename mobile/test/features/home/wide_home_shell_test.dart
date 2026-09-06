import 'package:buzz/features/activity/activity_page.dart';
import 'package:buzz/features/activity/activity_provider.dart';
import 'package:buzz/features/activity/compose_drafts_provider.dart';
import 'package:buzz/features/activity/feed_item.dart';
import 'package:buzz/features/activity/reminders_provider.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_detail_page.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/channel_messages_provider.dart';
import 'package:buzz/features/channels/channel_mutes/channel_mutes_provider.dart';
import 'package:buzz/features/channels/channel_stars/channel_stars_provider.dart';
import 'package:buzz/features/channels/channel_typing_provider.dart';
import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/features/channels/channels_page.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/thread_detail_page.dart';
import 'package:buzz/features/channels/deep_link_dispatcher.dart';
import 'package:buzz/features/channels/mobile_huddle_controller.dart';
import 'package:buzz/features/channels/wide_shell/wide_shell_provider.dart';
import 'package:buzz/features/channels/wide_shell/wide_sidebar_collapsed_provider.dart';
import 'package:buzz/features/home/adaptive_home.dart';
import 'package:buzz/features/home/home_nav_rows.dart';
import 'package:buzz/features/home/home_page.dart';
import 'package:buzz/features/home/wide_home_shell.dart';
import 'package:buzz/features/profile/profile_avatar.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/features/search/recent_searches_provider.dart';
import 'package:buzz/features/search/search_page.dart';
import 'package:buzz/features/search/search_provider.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_icon_provider.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/deeplink/pending_deep_link_provider.dart';
import 'package:buzz/shared/layout/layout_mode.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/read_state/read_state_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _generalId = '11111111-2222-4333-8444-555555555555';
const _randomId = '22222222-2222-4333-8444-555555555555';

Channel _channel(String id, String name) => Channel(
  id: id,
  name: name,
  channelType: 'stream',
  visibility: 'open',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 3,
  isMember: true,
);

final _channels = [
  _channel(_generalId, 'general'),
  _channel(_randomId, 'random'),
];

class _FakeChannelsNotifier extends ChannelsNotifier {
  @override
  Future<List<Channel>> build() => SynchronousFuture(_channels);
}

class _FakeProfileNotifier extends ProfileNotifier {
  @override
  Future<UserProfile?> build() async =>
      const UserProfile(pubkey: 'aabb', displayName: 'Test');
}

class _FakePresenceNotifier extends PresenceNotifier {
  @override
  Future<String> build() async => 'online';
}

class _FakeMessagesNotifier extends ChannelMessagesNotifier {
  _FakeMessagesNotifier(super.channelId);

  @override
  AsyncValue<List<NostrEvent>> build() => const AsyncData([]);

  @override
  bool get hasLoadedMessages => true;

  @override
  bool get reachedOldest => true;
}

class _FakeTypingNotifier extends ChannelTypingNotifier {
  _FakeTypingNotifier(super.channelId);

  @override
  List<TypingEntry> build() => const [];
}

class _FakeUserCacheNotifier extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => const {};

  @override
  UserProfile? get(String pubkey) => null;

  @override
  Future<bool> preload(List<String> pubkeys) async => true;

  @override
  Future<bool> refresh(List<String> pubkeys) async => true;
}

class _FakeReadStateNotifier extends ReadStateNotifier {
  @override
  ReadStateState build() => const ReadStateState(
    isReady: true,
    pubkey: 'aabb',
    contexts: {},
    version: 1,
  );

  @override
  void seedContextRead(String contextId, int unixTimestamp) {}

  @override
  void markContextRead(
    String contextId,
    int unixTimestamp, {
    bool clearForcedMessages = false,
  }) {}
}

class _FakeChannelStarsNotifier extends ChannelStarsNotifier {
  @override
  ChannelStarsState build() => const ChannelStarsState(isReady: true);
}

class _FakeChannelMutesNotifier extends ChannelMutesNotifier {
  @override
  ChannelMutesState build() => const ChannelMutesState(isReady: true);
}

class _FakeActivityNotifier extends ActivityNotifier {
  @override
  Future<HomeFeedResponse> build() async => HomeFeedResponse(
    mentions: const [],
    needsAction: const [],
    activity: const [],
    agentActivity: const [],
  );
}

class _FakeRemindersNotifier extends RemindersNotifier {
  @override
  Future<List<Reminder>> build() async => const [];
}

class _FakeComposeDraftsNotifier extends ComposeDraftsNotifier {
  @override
  List<ComposeDraft> build() => const [];
}

class _FakeSearchNotifier extends SearchNotifier {
  @override
  SearchState build() => const SearchState.initial();
}

class _FakeRecentSearchesNotifier extends RecentSearchesNotifier {
  @override
  List<String> build() => const [];
}

class _TestAppLifecycleNotifier extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}

class _QueuedPendingDeepLinkNotifier extends PendingDeepLinkNotifier {
  _QueuedPendingDeepLinkNotifier(this._links);

  final List<BuzzDeepLink> _links;

  @override
  BuzzDeepLink? build() => _links.isEmpty ? null : _links.first;

  @override
  void consume() {
    if (_links.isNotEmpty) _links.removeAt(0);
    state = _links.isEmpty ? null : _links.first;
  }
}

Widget _buildSettingsPage(BuildContext context) => const SizedBox.shrink();

Future<Widget> _buildApp({
  Map<String, Object> prefs = const {},
  bool hasUnreadInbox = false,
  List<BuzzDeepLink> deepLinks = const [],
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPrefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      savedPrefsProvider.overrideWithValue(sharedPrefs),
      activeCommunityProvider.overrideWith(
        (ref) async => Community(
          id: 'community',
          name: 'Test',
          relayUrl: 'wss://relay.example',
          addedAt: DateTime(2025),
        ),
      ),
      myPubkeyProvider.overrideWithValue('aabb'),
      channelsProvider.overrideWith(_FakeChannelsNotifier.new),
      profileProvider.overrideWith(_FakeProfileNotifier.new),
      presenceProvider.overrideWith(_FakePresenceNotifier.new),
      communityIconProvider.overrideWith((ref, relayUrl) async => null),
      dmDirectoryPreviewEnabledProvider.overrideWith((ref) => false),
      userCacheProvider.overrideWith(_FakeUserCacheNotifier.new),
      readStateProvider.overrideWith(_FakeReadStateNotifier.new),
      channelStarsProvider.overrideWith(_FakeChannelStarsNotifier.new),
      channelMutesProvider.overrideWith(_FakeChannelMutesNotifier.new),
      knownAgentPubkeysProvider.overrideWithValue(const {}),
      agentOwnersProvider.overrideWith((ref) async => const {}),
      agentDirectoryProvider.overrideWith((ref) async => const []),
      relayClientProvider.overrideWithValue(
        RelayClient(baseUrl: 'http://localhost:3000'),
      ),
      appLifecycleProvider.overrideWith(_TestAppLifecycleNotifier.new),
      activityProvider.overrideWith(_FakeActivityNotifier.new),
      remindersProvider.overrideWith(_FakeRemindersNotifier.new),
      composeDraftsProvider.overrideWith(_FakeComposeDraftsNotifier.new),
      searchProvider.overrideWith(_FakeSearchNotifier.new),
      recentSearchesProvider.overrideWith(_FakeRecentSearchesNotifier.new),
      pendingDeepLinkProvider.overrideWith(
        () => _QueuedPendingDeepLinkNotifier([...deepLinks]),
      ),
      for (final channel in _channels) ...[
        channelMessagesProvider(
          channel.id,
        ).overrideWith(() => _FakeMessagesNotifier(channel.id)),
        channelTypingProvider(
          channel.id,
        ).overrideWith(() => _FakeTypingNotifier(channel.id)),
        channelDetailsProvider(
          channel.id,
        ).overrideWith((ref) async => ChannelDetails.fromChannel(channel)),
        channelCanvasProvider(channel.id).overrideWith(
          (ref) async =>
              ChannelCanvas(content: '', updatedAt: null, authorPubkey: null),
        ),
        channelMembersProvider(
          channel.id,
        ).overrideWith((ref) async => const []),
        channelBotPubkeysProvider(
          channel.id,
        ).overrideWith((ref) async => const <String>{}),
        huddleLifecycleProvider(
          channel.id,
        ).overrideWith((ref) async => const []),
      ],
      ...overrides,
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: DeepLinkDispatcher(
        child: AdaptiveHome(
          settingsPageBuilder: _buildSettingsPage,
          hasUnreadInbox: hasUnreadInbox,
        ),
      ),
    ),
  );
}

void _useIpadWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1194, 834);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  _focusTests();
  testWidgets('a failure is reported once, in the pane that raised it', (
    tester,
  ) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(await _buildApp());
    await tester.pumpAndSettle();
    final shell = tester.element(find.byType(WideHomeShell));
    final container = ProviderScope.containerOf(shell, listen: false);
    container.read(wideShellProvider.notifier).selectChannel(_channels.first);
    await tester.pumpAndSettle();

    // One messenger shows a snackbar in every root Scaffold registered with
    // it, and the shell's columns are sibling Scaffolds — a shared messenger
    // reported a single failed send once per visible pane.
    final paneContext = tester.element(find.byType(ChannelDetailPage));
    ScaffoldMessenger.of(
      paneContext,
    ).showSnackBar(const SnackBar(content: Text('rate-limited: probe')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('rate-limited: probe'), findsOneWidget);
    final snackBar = tester.getRect(find.text('rate-limited: probe'));
    final pane = tester.getRect(find.byType(ChannelDetailPage));
    expect(
      snackBar.center.dx,
      greaterThan(pane.left),
      reason: 'the report belongs to the pane that raised it',
    );
    expect(snackBar.center.dx, lessThan(pane.right));
  });

  testWidgets('a phone window renders the stacked home and pushes Activity '
      'and Search', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(await _buildApp(hasUnreadInbox: true));
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(WideHomeShell), findsNothing);
    final context = tester.element(find.byType(HomePage));
    expect(LayoutModeScope.of(context), LayoutMode.compact);
    // The wide shell's sidebar at full width: rows under the header, the
    // profile card as the footer, no tab bar.
    expect(find.byType(HomeNavRows), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-nav-activity-unread-dot')),
      findsOneWidget,
    );
    expect(find.byType(SidebarProfileCard), findsOneWidget);
    expect(find.byTooltip('Home'), findsNothing);
    expect(find.byType(ProfileAvatar), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-nav-activity')));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityPage), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-nav-search')));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'pushed to type into',
    );
  });

  testWidgets('an iPad window renders the three-column shell', (tester) async {
    _useIpadWindow(tester);

    await tester.pumpWidget(await _buildApp(hasUnreadInbox: true));
    await tester.pumpAndSettle();

    expect(find.byType(WideHomeShell), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
    expect(find.byType(ChannelsPage), findsOneWidget);
    expect(find.byKey(const ValueKey('home-nav-activity')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-nav-activity-unread-dot')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('wide-main-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-sidebar-toggle')), findsOneWidget);
  });

  testWidgets(
    'a macOS window renders the three-column shell and Escape unwinds it',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      // The client window never shrinks below 1000x700 (MainFlutterWindow);
      // 1280x800 is its default size.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(await _buildApp());
        await tester.pumpAndSettle();

        expect(find.byType(WideHomeShell), findsOneWidget);
        expect(find.byType(HomePage), findsNothing);
        // No iOS-only native chrome is ever constructed on the Mac.
        expect(find.byType(UiKitView), findsNothing);

        final shell = tester.element(find.byType(WideHomeShell));
        final container = ProviderScope.containerOf(shell, listen: false);
        final notifier = container.read(wideShellProvider.notifier);
        notifier.selectChannel(_channels.first);
        await tester.pumpAndSettle();
        notifier.openAux(
          const WideAuxThread(
            threadHead: _threadHead,
            allMessages: [_threadHead],
            channelId: _generalId,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ThreadDetailPage), findsOneWidget);

        // Escape closes the thread pane, like system back does on a tablet.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(container.read(wideShellProvider).aux, isNull);
        expect(find.byType(ThreadDetailPage), findsNothing);
        // With nothing left to unwind the channel stays selected.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(ChannelDetailPage), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  testWidgets(
    'the sidebar ends in a profile card and hides the header avatar',
    (tester) async {
      _useIpadWindow(tester);
      await tester.pumpWidget(await _buildApp());
      await tester.pumpAndSettle();

      final card = find.byKey(const ValueKey('sidebar-profile-card'));
      expect(card, findsOneWidget);
      // The only profile avatar on screen is the card's: the channel list
      // header no longer carries the Settings avatar in the wide shell.
      expect(find.byType(ProfileAvatar), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byType(ProfileAvatar)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey('sidebar-profile-card-name')),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('sidebar-profile-card-name')),
            )
            .data,
        'Test',
      );
      // The community is named in the header at the top of the sidebar;
      // the card does not repeat it.
      expect(find.text('🐝'), findsNothing);
      expect(
        find.descendant(of: card, matching: find.text('Test')),
        findsOneWidget,
        reason: 'only the display name',
      );
    },
  );

  testWidgets('the profile card opens Settings', (tester) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(await _buildApp());
    await tester.pumpAndSettle();
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    expect(rootNavigator.canPop(), isFalse);

    // The Settings route reports transition progress on every frame; pump
    // bounded frames rather than waiting for the page beneath to go idle.
    await tester.tap(find.byKey(const ValueKey('sidebar-profile-card')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(rootNavigator.canPop(), isTrue, reason: 'Settings was pushed');
    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(rootNavigator.canPop(), isFalse);
  });

  testWidgets('tapping a channel selects the main pane without pushing', (
    tester,
  ) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(await _buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('channel-icon-$_generalId')));
    await tester.pumpAndSettle();

    final shell = tester.element(find.byType(WideHomeShell));
    final container = ProviderScope.containerOf(shell, listen: false);
    expect(container.read(wideShellProvider).selectedChannelId, _generalId);
    expect(find.byType(ChannelDetailPage), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-main-empty')), findsNothing);
    // The root navigator did not push: the list is still on screen.
    expect(find.byType(ChannelsPage), findsOneWidget);
    expect(Navigator.of(shell).canPop(), isFalse);
    // The channel page shows the sidebar toggle instead of a back button.
    expect(
      find.descendant(
        of: find.byType(ChannelDetailPage),
        matching: find.byKey(const ValueKey('wide-sidebar-toggle')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Activity and Search replace the main pane content', (
    tester,
  ) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(await _buildApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('channel-icon-$_generalId')));
    await tester.pumpAndSettle();
    expect(find.byType(ChannelDetailPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-nav-activity')));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityPage), findsOneWidget);
    expect(find.byType(ChannelDetailPage), findsNothing);

    await tester.tap(find.byKey(const ValueKey('home-nav-search')));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byType(ActivityPage), findsNothing);

    await tester.tap(find.byKey(const ValueKey('channel-icon-$_randomId')));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsNothing);
    expect(find.byType(ChannelDetailPage), findsOneWidget);
  });

  testWidgets('the sidebar toggle collapses the sidebar and persists', (
    tester,
  ) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(await _buildApp());
    await tester.pumpAndSettle();
    final sidebarWidth = tester.getSize(find.byType(ChannelsPage)).width;
    expect(sidebarWidth, kWideSidebarWidth);

    await tester.tap(find.byKey(const ValueKey('wide-sidebar-toggle')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('buzz.wide-sidebar-collapsed.v1'), isTrue);
    final shell = tester.element(find.byType(WideHomeShell));
    expect(
      ProviderScope.containerOf(
        shell,
        listen: false,
      ).read(wideSidebarCollapsedProvider),
      isTrue,
    );
    // The sidebar is hidden but keeps its state; the toggle is still there.
    expect(find.byKey(const ValueKey('wide-sidebar-toggle')), findsOneWidget);
  });

  testWidgets('a persisted collapsed sidebar starts hidden', (tester) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(
      await _buildApp(prefs: {'buzz.wide-sidebar-collapsed.v1': true}),
    );
    await tester.pumpAndSettle();

    final shell = tester.element(find.byType(WideHomeShell));
    expect(
      ProviderScope.containerOf(
        shell,
        listen: false,
      ).read(wideSidebarCollapsedProvider),
      isTrue,
    );
    final mainPaneWidth = tester.getSize(find.byType(ChannelsPage)).width;
    expect(mainPaneWidth, kWideSidebarWidth, reason: 'kept mounted, clipped');
    final toggle = tester.getTopLeft(
      find.byKey(const ValueKey('wide-sidebar-toggle')),
    );
    expect(toggle.dx, lessThan(kWideSidebarWidth));
  });

  testWidgets('a deep link selects the channel in the pane, even when the '
      'channel is already selected', (tester) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(
      await _buildApp(
        deepLinks: const [
          MessageDeepLink(
            channelId: _generalId,
            messageId: 'm1',
            threadRootId: null,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final shell = tester.element(find.byType(WideHomeShell));
    final container = ProviderScope.containerOf(shell, listen: false);
    expect(container.read(wideShellProvider).selectedChannelId, _generalId);
    expect(container.read(wideShellProvider).initialMessageId, 'm1');
    expect(find.byType(ChannelDetailPage), findsOneWidget);
    expect(Navigator.of(shell).canPop(), isFalse);
    final firstKey = container.read(wideShellProvider).mainPaneKey;

    container
        .read(pendingDeepLinkProvider.notifier)
        .state = const MessageDeepLink(
      channelId: _generalId,
      messageId: 'm2',
      threadRootId: null,
    );
    await tester.pumpAndSettle();

    expect(container.read(wideShellProvider).initialMessageId, 'm2');
    expect(container.read(wideShellProvider).mainPaneKey, isNot(firstKey));
  });
}

const _threadHead = TimelineMessage(
  id: 'root-1',
  pubkey: 'aabb',
  createdAt: 1000,
  content: 'root',
  tags: [],
  isSystem: false,
  edited: false,
  systemEvent: null,
  mentionPubkeys: [],
);

void _focusTests() {
  testWidgets('the thread pane shares the row, then focuses as a drawer '
      'over the channel', (tester) async {
    _useIpadWindow(tester);
    await tester.pumpWidget(await _buildApp());
    await tester.pumpAndSettle();
    final shell = tester.element(find.byType(WideHomeShell));
    final container = ProviderScope.containerOf(shell, listen: false);
    final notifier = container.read(wideShellProvider.notifier);

    notifier.selectChannel(_channels.first);
    await tester.pumpAndSettle();
    notifier.openAux(
      const WideAuxThread(
        threadHead: _threadHead,
        allMessages: [_threadHead],
        channelId: _generalId,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ThreadDetailPage), findsOneWidget);
    const contentWidth = 1194 - kWideSidebarWidth;
    double drawerWidth() =>
        tester.getSize(find.byKey(const ValueKey('wide-aux-drawer'))).width;
    bool scrimActive() => !tester
        .widget<IgnorePointer>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('wide-aux-focus-scrim')),
                matching: find.byType(IgnorePointer),
              )
              .first,
        )
        .ignoring;

    final sideWidth = wideAuxPaneWidthFor(contentWidth);
    expect(drawerWidth(), sideWidth);
    expect(sideWidth, closeTo(contentWidth * kWideAuxPaneFraction, 1));
    expect(scrimActive(), isFalse);
    // The channel yields exactly the panel's width.
    expect(
      tester.getSize(find.byType(ChannelDetailPage)).width,
      contentWidth - sideWidth,
    );

    await tester.tap(find.byKey(const ValueKey('wide-aux-focus')));
    await tester.pump();
    // Mid-animation the drawer is between the two widths.
    await tester.pump(const Duration(milliseconds: 80));
    expect(drawerWidth(), greaterThan(sideWidth));
    expect(drawerWidth(), lessThan(contentWidth - kWideAuxFocusGutter));
    await tester.pumpAndSettle();

    expect(scrimActive(), isTrue);
    expect(drawerWidth(), contentWidth - kWideAuxFocusGutter);
    // The channel stays mounted and reclaims the full row under the drawer.
    expect(find.byType(ChannelDetailPage), findsOneWidget);
    expect(tester.getSize(find.byType(ChannelDetailPage)).width, contentWidth);
    expect(container.read(wideShellProvider).auxFocused, isTrue);

    // Tapping the visible strip of the channel docks the thread again.
    await tester.tapAt(const Offset(kWideSidebarWidth + 20, 400));
    await tester.pumpAndSettle();
    expect(scrimActive(), isFalse);
    expect(drawerWidth(), sideWidth);

    await tester.tap(find.byKey(const ValueKey('wide-aux-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Closing slides the drawer shut with the thread still mounted.
    expect(find.byType(ThreadDetailPage), findsOneWidget);
    expect(drawerWidth(), lessThan(sideWidth));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('wide-aux-drawer')), findsNothing);
  });
}
