import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/features/channels/compose_bar.dart';

void main() {
  group('hasMention', () {
    test('matches plain mentions', () {
      expect(hasMention('hey @alpha how are you', 'alpha'), isTrue);
      expect(hasMention('@alpha', 'alpha'), isTrue);
      expect(hasMention('hey @alphabet', 'alpha'), isFalse);
    });

    test('matches every member of a team-expanded mention', () {
      const text = 'Nom Trio(@alpha @beta) please review';
      expect(hasMention(text, 'alpha'), isTrue);
      expect(hasMention(text, 'beta'), isTrue);
      expect(hasMention(text, 'gamma'), isFalse);
    });
  });
}
