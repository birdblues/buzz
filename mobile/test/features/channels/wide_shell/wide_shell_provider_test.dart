import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/features/channels/wide_shell/wide_shell_provider.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

Channel _channel(String id) => Channel(
  id: id,
  name: id,
  channelType: 'stream',
  visibility: 'open',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 1,
  isMember: true,
);

TimelineMessage _message(String id) => TimelineMessage(
  id: id,
  pubkey: 'aabb',
  createdAt: 1000,
  content: id,
  tags: const [],
  isSystem: false,
  edited: false,
  systemEvent: null,
  mentionPubkeys: const [],
);

class _CommunityIdNotifier extends Notifier<String> {
  @override
  String build() => 'community-a';

  void set(String id) => state = id;
}

final _communityIdProvider = NotifierProvider<_CommunityIdNotifier, String>(
  _CommunityIdNotifier.new,
);

class _FakeChannelsNotifier extends ChannelsNotifier {
  _FakeChannelsNotifier(this._channels);

  List<Channel> _channels;

  @override
  Future<List<Channel>> build() => SynchronousFuture(_channels);

  void setChannels(List<Channel> channels) {
    _channels = channels;
    state = AsyncData(channels);
  }

  void setRefreshing() {
    state = const AsyncLoading<List<Channel>>();
  }
}

void main() {
  late _FakeChannelsNotifier channels;
  late ProviderContainer container;

  setUp(() {
    channels = _FakeChannelsNotifier([_channel('a'), _channel('b')]);
    container = ProviderContainer(
      overrides: [
        activeCommunityProvider.overrideWith(
          (ref) async => Community(
            id: ref.watch(_communityIdProvider),
            name: 'Test',
            relayUrl: 'wss://relay.example',
            addedAt: DateTime(2025),
          ),
        ),
        myPubkeyProvider.overrideWithValue('aabb'),
        channelsProvider.overrideWith(() => channels),
      ],
    );
    addTearDown(container.dispose);
  });

  WideShellNotifier notifier() => container.read(wideShellProvider.notifier);
  WideShellState state() => container.read(wideShellProvider);

  test('selecting a channel shows it and remounts the main pane', () {
    final before = state().mainPaneKey;
    notifier().selectChannel(_channel('a'));
    expect(state().selectedChannelId, 'a');
    expect(state().surface, WideSurface.channel);
    expect(state().mainPaneKey, isNot(before));
  });

  test('re-selecting the same channel without targets keeps the pane', () {
    notifier().selectChannel(_channel('a'));
    final key = state().mainPaneKey;
    notifier().selectChannel(_channel('a'));
    expect(state().mainPaneKey, key);
  });

  test('a message target on the same channel remounts the pane', () {
    notifier().selectChannel(_channel('a'));
    final key = state().mainPaneKey;
    notifier().selectChannel(_channel('a'), initialMessageId: 'm1');
    expect(state().mainPaneKey, isNot(key));
    expect(state().initialMessageId, 'm1');
  });

  test('changing channel or surface closes the auxiliary pane', () {
    notifier().selectChannel(_channel('a'));
    notifier().openAux(
      WideAuxThread(
        threadHead: _message('m1'),
        allMessages: [_message('m1')],
        channelId: 'a',
      ),
    );
    expect(state().aux, isNotNull);
    expect(state().auxPaneKey, contains('thread-m1'));

    notifier().selectChannel(_channel('b'));
    expect(state().aux, isNull);

    notifier().openAux(
      const WideAuxForumThread(channelId: 'b', postEventId: 'p1'),
    );
    expect(state().aux, isA<WideAuxForumThread>());
    final mainKey = state().mainPaneKey;
    notifier().showInbox();
    expect(state().surface, WideSurface.inbox);
    expect(state().aux, isNull);
    expect(state().mainPaneKey, isNot(mainKey));
  });

  test('opening a thread from another channel selects that channel first', () {
    notifier().selectChannel(_channel('a'));
    notifier().openAux(
      WideAuxThread(
        threadHead: _message('m2'),
        allMessages: [_message('m2')],
        channelId: 'b',
      ),
    );
    expect(state().selectedChannelId, 'b');
    expect(state().aux?.channelId, 'b');
  });

  test('re-opening the same thread remounts the auxiliary pane', () {
    notifier().selectChannel(_channel('a'));
    final thread = WideAuxThread(
      threadHead: _message('m1'),
      allMessages: [_message('m1')],
      channelId: 'a',
    );
    notifier().openAux(thread);
    final key = state().auxPaneKey;
    notifier().openAux(thread);
    expect(state().auxPaneKey, isNot(key));
  });

  test('focus is a sticky toggle that survives closing the pane', () {
    notifier().selectChannel(_channel('a'));
    expect(state().auxFocused, isFalse);
    notifier().toggleAuxFocus();
    expect(state().auxFocused, isTrue);
    notifier().openAux(
      WideAuxThread(
        threadHead: _message('m1'),
        allMessages: [_message('m1')],
        channelId: 'a',
      ),
    );
    notifier().closeAux();
    expect(state().auxFocused, isTrue);
    notifier().toggleAuxFocus();
    expect(state().auxFocused, isFalse);
  });

  test('clears the selection when the channel leaves the loaded list', () {
    notifier().selectChannel(_channel('a'));
    container.listen(wideShellProvider, (_, _) {});

    channels.setRefreshing();
    expect(state().selectedChannelId, 'a', reason: 'loading keeps state');

    channels.setChannels([_channel('b')]);
    expect(state().selectedChannelId, isNull);
  });

  test('refreshes the channel snapshot from the loaded list', () {
    notifier().selectChannel(_channel('a'));
    container.listen(wideShellProvider, (_, _) {});
    final renamed = Channel(
      id: 'a',
      name: 'renamed',
      channelType: 'stream',
      visibility: 'open',
      description: '',
      createdBy: 'x',
      createdAt: DateTime(2025),
      memberCount: 1,
      isMember: true,
    );
    channels.setChannels([renamed, _channel('b')]);
    expect(state().selectedChannel?.name, 'renamed');
  });

  test('switching community resets the shell', () async {
    notifier().selectChannel(_channel('a'));
    container.listen(wideShellProvider, (_, _) {});
    await container.read(activeCommunityProvider.future);

    container.read(_communityIdProvider.notifier).set('community-b');
    await container.read(activeCommunityProvider.future);

    expect(state().selectedChannelId, isNull);
  });
}
