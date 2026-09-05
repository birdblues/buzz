import 'package:buzz/features/channels/app_webview_page.dart';
import 'package:buzz/features/forum/forum_models.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/forum/forum_thread_page.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/shared/layout/pane_navigator.dart';
import 'package:buzz/shared/layout/pane_scope.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

const _channelId = 'forum-channel';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _appUrl = 'https://relay.example.com/media/$_sha.html';
const _door = 'http://relay.example.com:3001';

ForumPost _appPost() => const ForumPost(
  eventId: 'post1',
  pubkey: 'alice',
  content: 'Try the diagram\n\n[seq.html]($_appUrl)',
  kind: 45001,
  createdAt: 1000,
  channelId: _channelId,
  tags: [
    ['h', _channelId],
    ['imeta', 'url $_appUrl', 'm text/html', 'x $_sha', 'filename seq.html'],
  ],
);

late SharedPreferences _prefs;

Widget _threadPage({bool inPane = false}) {
  final page = ForumThreadPage(
    channelId: _channelId,
    postEventId: 'post1',
    currentPubkey: 'self',
    isMember: true,
    isArchived: false,
  );
  return ProviderScope(
    overrides: [
      userCacheProvider.overrideWith(() => _FakeUserCacheNotifier()),
      knownAgentPubkeysProvider.overrideWithValue(const {}),
      channelBotPubkeysProvider(
        _channelId,
      ).overrideWith((ref) async => const {}),
      profileProvider.overrideWith(() => _FakeProfileNotifier()),
      forumThreadProvider((
        channelId: _channelId,
        eventId: 'post1',
      )).overrideWith(
        (ref) async => ForumThreadResponse(
          post: _appPost(),
          replies: const [],
          totalReplies: 0,
        ),
      ),
      savedPrefsProvider.overrideWithValue(_prefs),
      relayClientProvider.overrideWithValue(
        RelayClient(baseUrl: 'http://localhost:3000'),
      ),
      appContentUrlProvider.overrideWithValue(_door),
      mediaHttpClientProvider.overrideWithValue(
        http_testing.MockClient((_) async => http.Response('', 404)),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: inPane
          ? PaneNavigator(kind: PaneKind.aux, onClose: () {}, child: page)
          : page,
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('Run on a forum post opens the sandbox page', (tester) async {
    await tester.pumpWidget(_threadPage());
    await tester.pumpAndSettle();

    final run = find.byKey(const ValueKey('app-card-run'));
    expect(run, findsOneWidget);
    await tester.tap(run);
    await tester.pumpAndSettle();

    expect(find.byType(AppWebViewPage), findsOneWidget);
  });

  testWidgets('Run works when the thread lives in a wide-shell pane', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_threadPage(inPane: true));
    await tester.pumpAndSettle();

    final run = find.byKey(const ValueKey('app-card-run'));
    expect(run, findsOneWidget);
    await tester.tap(run);
    await tester.pumpAndSettle();

    expect(find.byType(AppWebViewPage), findsOneWidget);
  });
}

class _FakeUserCacheNotifier extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => const {
    'alice': UserProfile(pubkey: 'alice', displayName: 'Alice'),
  };

  @override
  UserProfile? get(String pubkey) => build()[pubkey.toLowerCase()];
}

class _FakeProfileNotifier extends ProfileNotifier {
  @override
  Future<UserProfile?> build() async =>
      const UserProfile(pubkey: 'self', displayName: 'Self');
}
