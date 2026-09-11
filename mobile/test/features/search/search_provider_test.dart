import 'dart:async';

import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/search/search_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// The real SearchNotifier against a relay whose two async lookups (messages
// over fetchHistory, people over searchUsers) are completed by hand, so the
// tests choose the order they land in. The page tests fake the whole
// notifier and never reach this logic.
class _Harness {
  _Harness() {
    session = _FakeRelaySession();
    container = ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_FakeRelayConfig.new),
        relaySessionProvider.overrideWith(() => session),
        channelsProvider.overrideWith(_FakeChannelsNotifier.new),
        channelActionsProvider.overrideWith(
          (ref) => actions = _FakeChannelActions(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  late final ProviderContainer container;
  late final _FakeRelaySession session;
  late _FakeChannelActions actions;

  SearchState get state => container.read(searchProvider);

  /// Types [query] and lets the 300 ms debounce fire.
  Future<void> search(String query) async {
    container.read(searchProvider.notifier).search(query);
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
}

void main() {
  const npub =
      'npub1x6q8zruqrdfzqv05c4vkaray859e75z44fjful0qs6vqxfk2lffs0jdr3f';

  test(
    'loading ends when the last lookup lands, even if it is also empty',
    () async {
      // A pasted npub matches no message and no profile text, and the
      // message search answers first. Before the fix the empty people lookup
      // then flipped isLoading back on and nothing cleared it.
      final h = _Harness();
      await h.search(npub);
      expect(h.state.isLoading, isTrue);

      h.session.messages.complete(const []);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.isLoading, isTrue, reason: 'people still pending');

      h.actions.users.complete(const []);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.isLoading, isFalse);
      expect(h.state.messageResults, isEmpty);
      expect(h.state.userResults, isEmpty);
    },
  );

  test('loading ends in the other order too', () async {
    final h = _Harness();
    await h.search(npub);

    h.actions.users.complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.isLoading, isTrue, reason: 'messages still pending');

    h.session.messages.complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.isLoading, isFalse);
  });

  test('a failed message lookup keeps loading until people land', () async {
    final h = _Harness();
    await h.search('anything');

    h.session.messages.completeError(Exception('relay history timed out'));
    await Future<void>.delayed(Duration.zero);
    expect(h.state.error, contains('timed out'));
    expect(h.state.isLoading, isTrue);

    h.actions.users.complete(const [DirectoryUser(pubkey: 'a1')]);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.isLoading, isFalse);
    expect(h.state.userResults, hasLength(1));
  });

  test('a failed people lookup still ends loading', () async {
    final h = _Harness();
    await h.search('anything');

    h.session.messages.complete(const []);
    h.actions.users.completeError(Exception('bridge down'));
    await Future<void>.delayed(Duration.zero);
    expect(h.state.isLoading, isFalse);
    expect(h.state.error, isNull, reason: 'people failure is non-critical');
  });

  test('a lookup finishing for a stale query does not end loading', () async {
    final h = _Harness();
    await h.search('first');
    final staleMessages = h.session.messages;
    final staleUsers = h.actions.users;

    h.session.messages = Completer();
    h.actions.users = Completer();
    await h.search('second');
    staleMessages.complete(const []);
    staleUsers.complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.query, 'second');
    expect(h.state.isLoading, isTrue);

    h.session.messages.complete(const []);
    h.actions.users.complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.isLoading, isFalse);
  });
}

class _FakeRelayConfig extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'ws://relay.test');
}

class _FakeRelaySession extends RelaySessionNotifier {
  Completer<List<NostrEvent>> messages = Completer();

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> fetchHistory(
    NostrFilter filter, {
    Duration timeout = const Duration(seconds: 8),
  }) => messages.future;
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  @override
  Future<List<Channel>> build() async => const [];
}

class _FakeChannelActions extends ChannelActions {
  _FakeChannelActions(Ref ref)
    : super(
        ref: ref,
        session: ref.read(relaySessionProvider.notifier),
        signedEventRelay: SignedEventRelay(
          session: ref.read(relaySessionProvider.notifier),
          nsec: null,
        ),
        currentPubkey: 'self',
      );

  Completer<List<DirectoryUser>> users = Completer();

  @override
  Future<List<DirectoryUser>> searchUsers(String query, {int limit = 8}) =>
      users.future;
}
