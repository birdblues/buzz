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

    test('a key the reader would not see as a mention addresses nobody', () {
      // The set this returns is the set the reader sees as chips. Where the
      // renderer refuses — a key touching a backtick, so a CommonMark
      // double-backtick span cannot draw a chip between two visible ticks, and
      // a key inside link or image syntax, which renders as a label, alt text
      // or a URL — nobody is addressed either. Otherwise the addressee gets a
      // notification for a mention no reader can see, not even its author.
      expect(nostrUriMentionPubkeys('a ``nostr:$npub`` b'), isEmpty);
      expect(nostrUriMentionPubkeys('a `nostr:$npub b'), isEmpty);
      expect(
        nostrUriMentionPubkeys('[nostr:$npub](https://example.com)'),
        isEmpty,
      );
      expect(nostrUriMentionPubkeys('[Alice](nostr:$npub)'), isEmpty);
      expect(
        nostrUriMentionPubkeys('![nostr:$npub](https://example.com/a.png)'),
        isEmpty,
      );
      // The relay's extractor addresses all of these. Addressing fewer people
      // than it does leaves a visible mention undelivered, which a reader can
      // see and fix; the reverse cannot be seen at all.
    });

    test('an indented block is prose to the relay, and to the reader', () {
      // Recorded, not endorsed: neither the extractor nor this renderer treats
      // an indented block as code, so a key there is addressed and chipped.
      expect(nostrUriMentionPubkeys('para\n\n    nostr:$npub\n'), [hex]);
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
