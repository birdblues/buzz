// The composer's suggestion/attachment overlay is an OverlayPortal, and the
// framework grafts a portal's overlay child under the composer in the
// semantics tree. If that child exists while the composer is hidden from
// semantics (a fading route, the thread page's initial viewport gate), the
// framework sends the child without a parent and the macOS/Windows engines
// drop the update — then every later one touching the same nodes
// (`accessibility_bridge.cc: Failed to update ui::AXTree`).
//
// These tests replay the framework's updates through the engines' checks
// (`test/support/ax_bridge_sim.dart`) around the real ComposeBar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:image_picker/image_picker.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/compose_bar.dart';
import 'package:buzz/features/channels/photo_library.dart';
import 'package:buzz/shared/custom_emoji/custom_emoji_provider.dart';
import 'package:buzz/shared/link_preview/link_preview_fetcher.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/ax_bridge_sim.dart';

void main() {
  final binding = AxBridgeSimBinding.ensureInitialized();
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binding.sim.reset();
    binding.labels.clear();
  });

  Widget buildPage({required ValueNotifier<bool> composerVisible}) {
    return ProviderScope(
      overrides: [
        customEmojiListProvider.overrideWithValue(const []),
        mediaUploadServiceProvider.overrideWithValue(
          MediaUploadService(
            baseUrl: 'https://relay.example',
            nsec: nostr.Keys.generate().nsec,
            pickGalleryImage: () async => null,
            pickGalleryVideo: () async => null,
          ),
        ),
        linkPreviewFetcherProvider.overrideWithValue(_NoLinkPreviews()),
        photoLibraryProvider.overrideWithValue(const _EmptyPhotoLibrary()),
        currentPubkeyProvider.overrideWith((ref) => null),
        channelMembersProvider(
          'channel-1',
        ).overrideWith((ref) async => const <ChannelMember>[]),
        agentDirectoryProvider.overrideWith(
          (ref) async => const <AgentDirectoryEntry>[],
        ),
        agentOwnersProvider.overrideWith(
          (ref) async => const <String, String>{},
        ),
        relayClientProvider.overrideWithValue(
          RelayClient(baseUrl: 'http://localhost:3000'),
        ),
        relayConfigProvider.overrideWith(_FakeRelayConfigNotifier.new),
        savedPrefsProvider.overrideWithValue(prefs),
        channelsProvider.overrideWith(_FakeChannelsNotifier.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < 5; i++) ListTile(title: Text('m$i')),
                  ],
                ),
              ),
              // The thread page gates its list and composer behind an
              // Opacity(0) until the initial viewport settles; a fading route
              // hides a new page the same way for its first frame.
              ValueListenableBuilder<bool>(
                valueListenable: composerVisible,
                builder: (context, visible, child) =>
                    Opacity(opacity: visible ? 1 : 0, child: child),
                child: ComposeBar(
                  channelId: 'channel-1',
                  onSend:
                      (
                        content,
                        mentionPubkeys, {
                        mediaTags = const <List<String>>[],
                      }) async {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String describe() => binding.sim.failures
      .map((f) {
        final ids = RegExp(
          r'\d+',
        ).allMatches(f.error).map((m) => int.parse(m.group(0)!)).toSet();
        final named = ids
            .map((id) => '$id=${binding.labels[id] ?? '?'}')
            .join('; ');
        return '$f\n  nodes: $named';
      })
      .join('\n');

  testWidgets(
    'a composer that mounts hidden from semantics never sends the engine '
    'an orphaned overlay child',
    (tester) async {
      final handle = tester.ensureSemantics();
      final visible = ValueNotifier<bool>(false);
      addTearDown(visible.dispose);

      await tester.pumpWidget(buildPage(composerVisible: visible));
      // Post-frame work (where the old code opened the portal) runs here,
      // while the composer is still hidden.
      await tester.pump();
      await tester.pump();
      expect(find.byType(ComposeBar), findsOneWidget);

      visible.value = true;
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(binding.sim.failures, isEmpty, reason: describe());
      // The composer is in the tree once visible.
      expect(find.byTooltip('Add attachment').hitTestable(), findsOneWidget);
      handle.dispose();
    },
  );

  testWidgets(
    'the overlay still opens for the attachment menu and closes with it, '
    'without rejected updates',
    (tester) async {
      final handle = tester.ensureSemantics();
      final visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);

      await tester.pumpWidget(buildPage(composerVisible: visible));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('attachment-menu')), findsNothing);

      await tester.tap(find.byTooltip('Add attachment').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('attachment-menu')), findsOneWidget);

      // Tapping the scrim above the composer dismisses the menu.
      await tester.tapAt(const Offset(24, 24));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('attachment-menu')), findsNothing);
      expect(
        find.byKey(const ValueKey('attachment-dismiss-barrier')),
        findsNothing,
      );

      expect(binding.sim.failures, isEmpty, reason: describe());
      handle.dispose();
    },
  );
}

class _FakeRelayConfigNotifier extends RelayConfigNotifier {
  @override
  RelayConfig build() => RelayConfig(
    baseUrl: 'http://localhost:3000',
    nsec: nostr.Keys.generate().nsec,
  );
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  @override
  Future<List<Channel>> build() async => const [];

  @override
  Future<void> refresh({bool fetchDirectory = false}) async {
    state = const AsyncData([]);
  }
}

class _EmptyPhotoLibrary implements PhotoLibrary {
  const _EmptyPhotoLibrary();

  @override
  Future<List<RecentPhoto>> loadRecentPhotos() async => const [];

  @override
  Future<List<XFile>> resolveSelectedPhotos(List<RecentPhoto> photos) async =>
      const [];
}

class _NoLinkPreviews extends LinkPreviewFetcher {
  _NoLinkPreviews()
    : super(
        clientFactory: () =>
            http_testing.MockClient((_) async => http.Response('', 404)),
      );

  @override
  Future<LinkPreviewCapture?> fetch(Uri url) async => null;
}
