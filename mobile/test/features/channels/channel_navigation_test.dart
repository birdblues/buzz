import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_navigation.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/features/channels/wide_shell/wide_shell_provider.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/layout/layout_mode.dart';
import 'package:buzz/shared/layout/pane_navigator.dart';
import 'package:buzz/shared/layout/pane_scope.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart';

final _channel = Channel(
  id: 'ch-1',
  name: 'general',
  channelType: 'stream',
  visibility: 'open',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 1,
  isMember: true,
);

const _head = TimelineMessage(
  id: 'm1',
  pubkey: 'aabb',
  createdAt: 1000,
  content: 'root',
  tags: [],
  isSystem: false,
  edited: false,
  systemEvent: null,
  mentionPubkeys: [],
);

class _RecordingObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  final popped = <Route<dynamic>>[];
  final replaced = <Route<dynamic>?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      popped.add(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      replaced.add(newRoute);
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  @override
  Future<List<Channel>> build() => SynchronousFuture([_channel]);
}

List<Override> _wideOverrides() => [
  activeCommunityProvider.overrideWith(
    (ref) async => Community(
      id: 'c',
      name: 'Test',
      relayUrl: 'wss://relay.example',
      addedAt: DateTime(2025),
    ),
  ),
  myPubkeyProvider.overrideWithValue('aabb'),
  channelsProvider.overrideWith(_FakeChannelsNotifier.new),
];

void main() {
  group('compact layout', () {
    testWidgets('openChannelDetail pushes a route', (tester) async {
      final observer = _RecordingObserver();
      late BuildContext homeContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      observer.pushed.clear();

      openChannelDetail(homeContext, channel: _channel);

      expect(observer.pushed, hasLength(1));
      expect(observer.pushed.single, isA<MaterialPageRoute<void>>());
      // Tear down before the pushed page builds; it needs the relay stack.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('openThreadDetail pushes, or replaces on request', (
      tester,
    ) async {
      final observer = _RecordingObserver();
      late BuildContext homeContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      observer.pushed.clear();

      openThreadDetail(
        homeContext,
        threadHead: _head,
        allMessages: const [_head],
        channelId: _channel.id,
        currentPubkey: 'aabb',
        isMember: true,
        isArchived: false,
      );
      expect(observer.pushed, hasLength(1));
      expect(observer.replaced, isEmpty);

      openThreadDetail(
        homeContext,
        threadHead: _head,
        allMessages: const [_head],
        channelId: _channel.id,
        currentPubkey: 'aabb',
        isMember: true,
        isArchived: false,
        replaceCurrentRoute: true,
      );
      expect(observer.replaced, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('closeChannelDetail pops the current route', (tester) async {
      final observer = _RecordingObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          home: const Scaffold(body: SizedBox()),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: Text('page'));
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('page'), findsOneWidget);

      closeChannelDetail(pageContext);
      await tester.pumpAndSettle();

      expect(find.text('page'), findsNothing);
      expect(observer.popped, hasLength(1));
    });
  });

  group('wide layout', () {
    Widget wideApp({
      required _RecordingObserver observer,
      required GlobalKey<NavigatorState> navigatorKey,
      required Widget home,
    }) {
      return ProviderScope(
        overrides: _wideOverrides(),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          home: LayoutModeScope(mode: LayoutMode.wide, child: home),
        ),
      );
    }

    testWidgets('openChannelDetail selects the pane instead of pushing', (
      tester,
    ) async {
      final observer = _RecordingObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      late BuildContext homeContext;
      await tester.pumpWidget(
        wideApp(
          observer: observer,
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      observer.pushed.clear();

      await openChannelDetail(
        homeContext,
        channel: _channel,
        initialMessageId: 'm9',
      );

      expect(observer.pushed, isEmpty);
      final container = ProviderScope.containerOf(homeContext, listen: false);
      final state = container.read(wideShellProvider);
      expect(state.selectedChannelId, _channel.id);
      expect(state.initialMessageId, 'm9');
    });

    testWidgets('a root route covering the shell is dismissed first', (
      tester,
    ) async {
      final observer = _RecordingObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      late BuildContext homeContext;
      await tester.pumpWidget(
        wideApp(
          observer: observer,
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('settings')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);

      await openChannelDetail(homeContext, channel: _channel);
      await tester.pumpAndSettle();

      expect(find.text('settings'), findsNothing);
      expect(observer.popped, hasLength(1));
      final container = ProviderScope.containerOf(homeContext, listen: false);
      expect(container.read(wideShellProvider).selectedChannelId, _channel.id);
    });

    testWidgets('openThreadDetail fills the auxiliary pane from the main pane '
        'and stacks inside the auxiliary pane', (tester) async {
      final observer = _RecordingObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      final auxDepth = ValueNotifier<int>(0);
      late BuildContext mainContext;
      late BuildContext auxContext;
      await tester.pumpWidget(
        wideApp(
          observer: observer,
          navigatorKey: navigatorKey,
          home: Row(
            children: [
              Expanded(
                child: PaneNavigator(
                  kind: PaneKind.main,
                  onClose: () {},
                  child: Builder(
                    builder: (context) {
                      mainContext = context;
                      return const SizedBox();
                    },
                  ),
                ),
              ),
              Expanded(
                child: PaneNavigator(
                  kind: PaneKind.aux,
                  onClose: () {},
                  depth: auxDepth,
                  child: Builder(
                    builder: (context) {
                      auxContext = context;
                      return const SizedBox();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      observer.pushed.clear();
      expect(auxDepth.value, 1);

      await openThreadDetail(
        mainContext,
        threadHead: _head,
        allMessages: const [_head],
        channelId: _channel.id,
        currentPubkey: 'aabb',
        isMember: true,
        isArchived: false,
      );
      final container = ProviderScope.containerOf(mainContext, listen: false);
      expect(container.read(wideShellProvider).aux, isA<WideAuxThread>());
      expect(observer.pushed, isEmpty);
      expect(auxDepth.value, 1);

      openThreadDetail(
        auxContext,
        threadHead: _head,
        allMessages: const [_head],
        channelId: _channel.id,
        currentPubkey: 'aabb',
        isMember: true,
        isArchived: false,
      );
      expect(auxDepth.value, 2, reason: 'nested thread stacks in the pane');
      expect(observer.pushed, isEmpty, reason: 'root navigator untouched');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('closeChannelDetail closes the pane', (tester) async {
      var closed = 0;
      late BuildContext paneContext;
      await tester.pumpWidget(
        MaterialApp(
          home: PaneNavigator(
            kind: PaneKind.main,
            onClose: () => closed++,
            child: Builder(
              builder: (context) {
                paneContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      closeChannelDetail(paneContext);

      expect(closed, 1);
    });
  });
}
