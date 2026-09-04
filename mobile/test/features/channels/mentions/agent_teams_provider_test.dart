import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/features/channels/mentions/agent_teams_provider.dart';
import 'package:buzz/shared/relay/relay.dart';

NostrEvent event({
  required int kind,
  required String dTag,
  required Object content,
}) => NostrEvent(
  id: 'e' * 64,
  pubkey: 'a' * 64,
  createdAt: 1,
  kind: kind,
  tags: [
    ['d', dTag],
  ],
  content: content is String ? content : jsonEncode(content),
  sig: '',
);

void main() {
  group('AgentTeamRecord.fromEvent', () {
    test('parses the projection field names desktop publishes', () {
      final team = AgentTeamRecord.fromEvent(
        event(
          kind: 30176,
          dTag: 'team-1',
          content: {
            'name': 'Nom Trio',
            'persona_ids': ['p-a', 'p-b'],
          },
        ),
      );

      expect(team, isNotNull);
      expect(team!.id, 'team-1');
      expect(team.name, 'Nom Trio');
      expect(team.personaIds, ['p-a', 'p-b']);
    });

    test('keeps absent persona_ids as unknown, not empty', () {
      final team = AgentTeamRecord.fromEvent(
        event(kind: 30176, dTag: 'team-1', content: {'name': 'Nom Trio'}),
      );

      expect(team!.personaIds, isNull);
    });

    test('tolerates malformed content without throwing', () {
      expect(
        AgentTeamRecord.fromEvent(
          event(kind: 30176, dTag: 'team-1', content: 'not json'),
        ),
        isNull,
      );
      expect(
        AgentTeamRecord.fromEvent(
          event(
            kind: 30176,
            dTag: 'team-1',
            content: {
              'name': 42,
              'persona_ids': ['p-a'],
            },
          ),
        ),
        isNull,
      );
      // Non-string persona ids are dropped, not fatal.
      final team = AgentTeamRecord.fromEvent(
        event(
          kind: 30176,
          dTag: 'team-1',
          content: {
            'name': 'Nom Trio',
            'persona_ids': [
              'p-a',
              7,
              ['nested'],
            ],
          },
        ),
      );
      expect(team!.personaIds, ['p-a']);
    });

    test('rejects a missing or empty d-tag', () {
      expect(
        AgentTeamRecord.fromEvent(
          event(kind: 30176, dTag: '', content: {'name': 'Nom Trio'}),
        ),
        isNull,
      );
    });
  });
}
