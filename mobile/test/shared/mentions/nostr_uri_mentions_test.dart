import 'package:buzz/shared/mentions/nostr_uri_mentions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;

/// Who a message addresses has to mean the same thing on both sides of the
/// wire, so every expectation here is the observed output of the relay's own
/// extractor — `strip_code_regions` + `extract_nostr_uris` in
/// `crates/buzz-sdk/src/mentions.rs`, run over these exact inputs. A case
/// where this file and that one disagree is a case where a chip promises a
/// delivery the addressee never gets, or the reverse.
void main() {
  const npub =
      'npub1x6q8zruqrdfzqv05c4vkaray859e75z44fjful0qs6vqxfk2lffs0jdr3f';
  const hex =
      '3680710f801b522031f4c5596e8fa43d0b9f5055aa649e7de086980326cafa53';

  group('nostrUriMentionPubkeys', () {
    test('addresses a key written in prose', () {
      expect(nostrUriMentionPubkeys('hey nostr:$npub there'), [hex]);
      // The relay reads a fixed 58-character window and ignores what runs
      // into it, so a key glued to other text still addresses its owner.
      expect(nostrUriMentionPubkeys('hi nostr:${npub}abc there'), [hex]);
      expect(nostrUriMentionPubkeys('key:nostr:$npub'), [hex]);
      // One person, named twice, is addressed once.
      expect(nostrUriMentionPubkeys('nostr:$npub and nostr:$npub'), [hex]);
    });

    test('a key written as code addresses nobody', () {
      expect(
        nostrUriMentionPubkeys('a\n\n```\nnostr:$npub\n```\n\nb'),
        isEmpty,
      );
      expect(nostrUriMentionPubkeys('```dart\nnostr:$npub\n```'), isEmpty);
      expect(nostrUriMentionPubkeys('```\nnostr:$npub\n'), isEmpty);
      expect(nostrUriMentionPubkeys('a `nostr:$npub` b'), isEmpty);
      expect(nostrUriMentionPubkeys('  ```\n  nostr:$npub\n  ```'), isEmpty);
    });

    test('what the relay still counts as prose, and so do we', () {
      // Recorded, not endorsed: the extractor's idea of code is narrower than
      // CommonMark's, and the client has to agree with the extractor rather
      // than with CommonMark. An indented block is not code to either of them,
      // and a double-backtick span reads as one empty inline span followed by
      // ordinary text.
      expect(nostrUriMentionPubkeys('para\n\n    nostr:$npub\n'), [hex]);
      expect(nostrUriMentionPubkeys('a ``nostr:$npub`` b'), [hex]);
    });

    test('a key glued to a backtick addresses nobody, unlike the relay', () {
      // The one place this is deliberately narrower. The pattern refuses a URI
      // touching a backtick so that a CommonMark double-backtick span does not
      // render a chip between two visible ticks; an unclosed backtick falls
      // under the same rule. The relay would address this person. Addressing
      // fewer people than the relay leaves a mention undelivered, which the
      // reader can see and fix — the reverse would promise a delivery nobody
      // made.
      expect(nostrUriMentionPubkeys('a `nostr:$npub b'), isEmpty);
    });

    test('an uppercase scheme addresses nobody', () {
      // `match_indices("nostr:npub1")` is literal.
      expect(nostrUriMentionPubkeys('hi NOSTR:$npub'), isEmpty);
    });

    test('stops at the cap the relay enforces', () {
      // Distinct keys, built by the codec so the count is real; the cap itself
      // is the expectation and comes from the relay, not from the codec.
      final body = [
        for (var i = 1; i <= nostrUriMentionCap + 10; i++)
          'nostr:${nostr.Nip19.encode(prefix: nostr.Nip19Prefix.npub, data: i.toRadixString(16).padLeft(64, '0'))}',
      ].join(' ');
      expect(nostrUriMentionPubkeys(body), hasLength(nostrUriMentionCap));

      // One person named many times is still one person.
      final repeated = List.filled(
        nostrUriMentionCap + 10,
        'nostr:$npub',
      ).join(' ');
      expect(nostrUriMentionPubkeys(repeated), [hex]);
    });

    test('an empty or keyless body is not scanned', () {
      expect(nostrUriMentionPubkeys(''), isEmpty);
      expect(nostrUriMentionPubkeys('no keys here at all'), isEmpty);
      expect(nostrUriMentionPubkeys('nostr:note1notakey'), isEmpty);
    });
  });

  group('stripCodeRegions', () {
    test('matches the extractor byte for byte', () {
      // Left-hand sides are the inputs; right-hand sides are what the Rust
      // implementation produced for them.
      expect(stripCodeRegions('a\n\n```\nx\n```\n\nb'), 'a\n\n \nb');
      expect(stripCodeRegions('```dart\nx\n```'), ' ');
      expect(stripCodeRegions('```\nx\n'), ' ');
      expect(stripCodeRegions('a `x` b'), 'a   b');
      expect(stripCodeRegions('a `x b'), 'a `x b');
      expect(stripCodeRegions('a ``x`` b'), 'a  x  b');
      expect(stripCodeRegions('para\n\n    x\n'), 'para\n\n    x\n');
      expect(stripCodeRegions('  ```\n  x\n  ```'), '   ');
      expect(stripCodeRegions('plain text'), 'plain text');
    });
  });
}
