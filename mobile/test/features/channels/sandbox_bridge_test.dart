import 'dart:convert';

import 'package:buzz/features/activity/compose_drafts_provider.dart';
import 'package:buzz/features/channels/sandbox_bridge.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixedRelayConfigNotifier extends RelayConfigNotifier {
  final RelayConfig _config;
  _FixedRelayConfigNotifier(this._config);

  @override
  RelayConfig build() => _config;
}

const _messageId =
    '1a2b3c4d5e6f70819a2b3c4d5e6f70819a2b3c4d5e6f70819a2b3c4d5e6f7081';

String _payload({
  Object? kind = 'edge',
  Object? ref = 'e4',
  Object? text = '[인과그래프] 간선 e4 가계 이자부담 → 민간소비 — 이 관계를 더 설명해줘',
}) => jsonEncode({'v': 1, 'kind': kind, 'ref': ref, 'text': text});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSandboxSelect', () {
    test('accepts the shape the native shim sends', () {
      final select = parseSandboxSelect(_payload());
      expect(select, isNotNull);
      expect(select!.kind, SandboxSelectKind.edge);
      expect(select.ref, 'e4');
      expect(select.text, startsWith('[인과그래프] 간선 e4'));
    });

    test('accepts every kind an app may point at', () {
      for (final kind in ['node', 'edge', 'path']) {
        expect(
          parseSandboxSelect(_payload(kind: kind)),
          isNotNull,
          reason: kind,
        );
      }
    });

    test('refuses anything that is not the shape', () {
      final rejected = <String, String>{
        'not json': 'nope',
        'empty': '',
        'array': '[1]',
        'string': '"hi"',
        'unknown kind': _payload(kind: 'window'),
        'kind not a string': _payload(kind: 1),
        'missing ref': jsonEncode({'kind': 'edge', 'text': 'x'}),
        'empty ref': _payload(ref: '  '),
        'multi-line ref': _payload(ref: 'a\nb'),
        'ref too long': _payload(ref: 'r' * 201),
        'missing text': jsonEncode({'kind': 'edge', 'ref': 'e4'}),
        'blank text': _payload(text: ' \n '),
        'text too long': _payload(text: 't' * 2049),
        'raw too long': _payload(text: 't' * 2000) + ' ' * (16 * 1024),
        'text not a string': _payload(text: ['x']),
      };
      rejected.forEach((reason, raw) {
        expect(parseSandboxSelect(raw), isNull, reason: reason);
      });
    });

    test('keeps a 2048-character text and a 200-character ref', () {
      final select = parseSandboxSelect(
        _payload(ref: 'r' * 200, text: 't' * 2048),
      );
      expect(select, isNotNull);
      expect(select!.text.length, 2048);
    });

    test('strips control characters from the text but keeps line breaks', () {
      final select = parseSandboxSelect(
        _payload(text: 'a\u0001b\u001bc\nd\te\u007f'),
      );
      expect(select!.text, 'abc\nd\te');
    });
  });

  group('sandboxBridgePrefillText', () {
    SandboxSelect select(String text) =>
        SandboxSelect(kind: SandboxSelectKind.edge, ref: 'e4', text: text);

    test('stamps the app tag into the leading bracket', () {
      expect(
        sandboxBridgePrefillText(
          select: select('[인과그래프] 간선 e4 A → B — 설명해줘'),
          messageId: _messageId,
        ),
        '[인과그래프 #1a2b3c4d] 간선 e4 A → B — 설명해줘',
      );
    });

    test('prefixes a generic tag when the text has none', () {
      expect(
        sandboxBridgePrefillText(
          select: select('간선 e4 A → B'),
          messageId: _messageId,
        ),
        '[앱 #1a2b3c4d] 간선 e4 A → B',
      );
      // A bracket that is not a tag (no space after it, or already tagged).
      expect(
        sandboxBridgePrefillText(select: select('[x]y'), messageId: _messageId),
        '[앱 #1a2b3c4d] [x]y',
      );
      expect(
        sandboxBridgePrefillText(
          select: select('[인과그래프 #deadbeef] 간선'),
          messageId: _messageId,
        ),
        '[앱 #1a2b3c4d] [인과그래프 #deadbeef] 간선',
      );
    });

    test('uses the whole id when it is shorter than the tag', () {
      expect(
        sandboxBridgePrefillText(select: select('[a] b'), messageId: 'abc'),
        '[a #abc] b',
      );
    });
  });

  group('SandboxBridgeRateLimiter', () {
    test('lets one message through per 500 ms', () {
      final limiter = SandboxBridgeRateLimiter();
      final t0 = DateTime(2026, 9, 7, 12);
      expect(limiter.allow(t0), isTrue);
      expect(limiter.allow(t0.add(const Duration(milliseconds: 100))), isFalse);
      expect(limiter.allow(t0.add(const Duration(milliseconds: 499))), isFalse);
      expect(limiter.allow(t0.add(const Duration(milliseconds: 500))), isTrue);
      // The dropped attempts did not move the window.
      expect(limiter.allow(t0.add(const Duration(milliseconds: 900))), isFalse);
      expect(limiter.allow(t0.add(const Duration(milliseconds: 1000))), isTrue);
    });
  });

  group('ComposerPrefillNotifier', () {
    Future<ProviderContainer> container() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          relayConfigProvider.overrideWith(
            () => _FixedRelayConfigNotifier(
              RelayConfig(baseUrl: 'https://relay.example'),
            ),
          ),
          myPubkeyProvider.overrideWithValue('pk'),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'persists the draft for the target composer and publishes it',
      () async {
        final c = await container();
        c
            .read(composerPrefillProvider.notifier)
            .request(channelId: 'ch1', threadHeadId: 'head', text: 'line one');

        final prefill = c.read(composerPrefillProvider);
        expect(prefill, isNotNull);
        expect(prefill!.key, 'ch1:head');
        expect(prefill.text, 'line one');
        final drafts = c.read(composeDraftsProvider.notifier);
        expect(drafts.textFor('ch1:head'), 'line one');
        expect(drafts.textFor('ch1'), isNull);
      },
    );

    test('appends to an existing draft on a new line', () async {
      final c = await container();
      c
          .read(composeDraftsProvider.notifier)
          .save(key: 'ch1', channelId: 'ch1', text: 'already typing');
      c
          .read(composerPrefillProvider.notifier)
          .request(channelId: 'ch1', text: 'phrase');

      expect(c.read(composerPrefillProvider)!.text, 'already typing\nphrase');
      expect(
        c.read(composeDraftsProvider.notifier).textFor('ch1'),
        'already typing\nphrase',
      );
    });

    test('every request is a new state, even with the same text', () async {
      final c = await container();
      final notifier = c.read(composerPrefillProvider.notifier);
      notifier.request(channelId: 'ch1', text: 'same');
      final first = c.read(composerPrefillProvider);
      notifier.request(channelId: 'ch2', text: 'same');
      final second = c.read(composerPrefillProvider);
      expect(first, isNot(equals(second)));
      expect(second!.key, 'ch2');
    });
  });
}
