import 'package:flutter_test/flutter_test.dart';

import 'package:buzz/shared/relay/relay_provider.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/community/community_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../community/community_storage_test.dart';

void main() {
  group('RelayConfig.baseUrl normalization', () {
    test('folds a wss:// community URL to https://', () {
      // Invite joins persist the relay URL straight off the invite link, which
      // deep_link.dart always emits as ws:// or wss://.
      final config = RelayConfig(baseUrl: 'wss://relay.example.com');
      expect(config.baseUrl, 'https://relay.example.com');
    });

    test('folds a ws:// community URL to http://', () {
      final config = RelayConfig(baseUrl: 'ws://relay.example.com:3000');
      expect(config.baseUrl, 'http://relay.example.com:3000');
    });

    test('leaves an https:// community URL untouched', () {
      // Device pairing rejects anything but https://, so these already conform.
      final config = RelayConfig(baseUrl: 'https://relay.example.com');
      expect(config.baseUrl, 'https://relay.example.com');
    });

    test('leaves an http:// community URL untouched', () {
      final config = RelayConfig(baseUrl: 'http://localhost:3000');
      expect(config.baseUrl, 'http://localhost:3000');
    });

    test('preserves a non-default port', () {
      final config = RelayConfig(baseUrl: 'wss://relay.example.com:8443');
      expect(config.baseUrl, 'https://relay.example.com:8443');
    });
  });

  group('RelayConfig.wsUrl', () {
    test('keeps TLS for a relay joined by invite', () {
      // Regression: a wss:// base used to fall through to the non-https branch
      // and downgrade to ws://, dialing port 80 — which never connects on a
      // relay that only serves 443, and drops TLS everywhere else.
      final config = RelayConfig(baseUrl: 'wss://relay.example.com');
      expect(config.wsUrl, 'wss://relay.example.com');
    });

    test('keeps TLS for a relay added by pairing', () {
      final config = RelayConfig(baseUrl: 'https://relay.example.com');
      expect(config.wsUrl, 'wss://relay.example.com');
    });

    test('both onboarding paths agree on the same relay', () {
      final invited = RelayConfig(baseUrl: 'wss://relay.example.com');
      final paired = RelayConfig(baseUrl: 'https://relay.example.com');
      expect(invited.wsUrl, paired.wsUrl);
      expect(invited.baseUrl, paired.baseUrl);
    });

    test('stays plaintext for local development', () {
      final config = RelayConfig(baseUrl: 'http://localhost:3000');
      expect(config.wsUrl, 'ws://localhost:3000');
    });

    test('preserves a non-default port', () {
      final config = RelayConfig(baseUrl: 'wss://relay.example.com:8443');
      expect(config.wsUrl, 'wss://relay.example.com:8443');
    });
  });

  group('RelayConfig equality', () {
    test('two configs for the same relay and key are equal', () {
      const a = RelayConfig(baseUrl: 'wss://relay.example.com', nsec: 'nsec1a');
      const b = RelayConfig(baseUrl: 'wss://relay.example.com', nsec: 'nsec1a');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(const RelayConfig(baseUrl: 'wss://relay.example.com', nsec: 'x')),
      );
      expect(
        a,
        isNot(const RelayConfig(baseUrl: 'wss://other', nsec: 'nsec1a')),
      );
    });

    test(
      'a community write that keeps the relay and key does not re-emit the config',
      () async {
        // Binds the production chain: community list → active community →
        // relay config. The relay session watches the config, so a re-emit
        // here is a socket reconnect. With push on, the desired-lease sync
        // writes the community after every channel reload, which turned one
        // reconnect into a self-sustaining storm.
        final storage = CommunityStorage(secure: FakeSecureStorage());
        final community = Community(
          id: 'c1',
          name: 'Before',
          relayUrl: 'wss://relay.example.com',
          pubkey: 'pk',
          nsec: 'nsec1a',
          addedAt: DateTime.utc(2026),
        );
        await storage.save(community);
        await storage.saveActiveId(community.id);
        final container = ProviderContainer(
          overrides: [communityStorageProvider.overrideWithValue(storage)],
        );
        addTearDown(container.dispose);

        await container.read(activeCommunityProvider.future);
        final first = container.read(relayConfigProvider);
        expect(first.baseUrl, 'https://relay.example.com');
        var configEmits = 0;
        container.listen(relayConfigProvider, (_, _) => configEmits++);

        await container
            .read(communityListProvider.notifier)
            .adoptRelayName(community.id, 'After');
        final active = await container.read(activeCommunityProvider.future);
        expect(active?.name, 'After', reason: 'the write itself landed');
        expect(configEmits, 0, reason: 'same relay, same key: no reconnect');
        expect(container.read(relayConfigProvider), equals(first));
      },
    );
  });
}
