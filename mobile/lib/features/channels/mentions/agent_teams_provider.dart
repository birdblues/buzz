import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/relay/relay.dart';
import '../channel_management_provider.dart';

/// An agent team parsed from the owner's kind:30176 team projection.
///
/// Mirrors the fields desktop's mention launcher consumes
/// (`buildTeamMentionCandidates` in mentionCandidates.ts): the team name and
/// its persona member ids. `personaIds` is null when the event omitted the
/// field (the projection's "unknown, preserve local" marker) — such a team
/// cannot be resolved here and is never offered as a mention candidate.
class AgentTeamRecord {
  final String id;
  final String name;
  final List<String>? personaIds;

  const AgentTeamRecord({
    required this.id,
    required this.name,
    this.personaIds,
  });

  static AgentTeamRecord? fromEvent(NostrEvent event) {
    final id = _dTag(event);
    if (id == null) return null;
    final content = _tryDecodeJsonMap(event.content);
    final name = _asString(content?['name'])?.trim();
    if (name == null || name.isEmpty) return null;
    final rawPersonaIds = content?['persona_ids'];
    return AgentTeamRecord(
      id: id,
      name: name,
      personaIds: rawPersonaIds is List
          ? [
              for (final value in rawPersonaIds)
                if (value is String) value,
            ]
          : null,
    );
  }
}

/// Owned teams plus the persona-to-agent-pubkey index needed to resolve
/// their members, both read from the owner's own kind:30176/30177
/// projections. Neither kind is shared-gated on the relay; the
/// `authors: [pubkey]` filter is what scopes this to the user's own teams.
class OwnedAgentTeams {
  final List<AgentTeamRecord> teams;

  /// Managed-agent pubkeys (kind:30177 d-tags) grouped by the persona id in
  /// the record's `persona_id` content field — the same local-id space the
  /// teams' `persona_ids` reference.
  final Map<String, List<String>> agentPubkeysByPersonaId;

  /// Managed-agent display names by pubkey, for members that are not
  /// independently mentionable in the current channel context.
  final Map<String, String> agentNamesByPubkey;

  const OwnedAgentTeams({
    this.teams = const [],
    this.agentPubkeysByPersonaId = const {},
    this.agentNamesByPubkey = const {},
  });
}

/// The current user's agent teams from their kind:30176/30177 projections.
///
/// Watches the session and only fetches after the WebSocket connects —
/// mirrors [agentDirectoryProvider]'s idiom.
final ownedAgentTeamsProvider = FutureProvider<OwnedAgentTeams>((ref) async {
  final sessionState = ref.watch(relaySessionProvider);
  if (sessionState.status != SessionStatus.connected) {
    return const OwnedAgentTeams();
  }
  final pubkey = ref.watch(currentPubkeyProvider);
  if (pubkey == null) return const OwnedAgentTeams();

  final session = ref.read(relaySessionProvider.notifier);
  final events = await session.fetchHistory(
    NostrFilters.ownedAgentTeams(pubkey),
  );

  // Addressable kinds are LWW per (kind, author, d); the relay stores only
  // the head, but keep the newest defensively in case duplicates arrive.
  final headByCoordinate = <String, NostrEvent>{};
  for (final event in events) {
    final dTag = _dTag(event);
    if (dTag == null) continue;
    final key = '${event.kind}:$dTag';
    final current = headByCoordinate[key];
    if (current == null || event.createdAt > current.createdAt) {
      headByCoordinate[key] = event;
    }
  }

  final teams = <AgentTeamRecord>[];
  final agentPubkeysByPersonaId = <String, List<String>>{};
  final agentNamesByPubkey = <String, String>{};
  for (final event in headByCoordinate.values) {
    switch (event.kind) {
      case 30176:
        final team = AgentTeamRecord.fromEvent(event);
        if (team != null) teams.add(team);
      case 30177:
        final agentPubkey = _dTag(event)?.toLowerCase();
        if (agentPubkey == null) continue;
        final content = _tryDecodeJsonMap(event.content);
        final personaId = _asString(content?['persona_id']);
        if (personaId != null) {
          (agentPubkeysByPersonaId[personaId] ??= []).add(agentPubkey);
        }
        final name = _asString(content?['name'])?.trim();
        if (name != null && name.isNotEmpty) {
          agentNamesByPubkey[agentPubkey] = name;
        }
    }
  }

  return OwnedAgentTeams(
    teams: teams,
    agentPubkeysByPersonaId: agentPubkeysByPersonaId,
    agentNamesByPubkey: agentNamesByPubkey,
  );
});

String? _dTag(NostrEvent event) {
  for (final tag in event.tags) {
    if (tag.length >= 2 && tag[0] == 'd') {
      // An empty d-tag would flow into candidates as an empty pubkey /
      // coordinate — treat it as absent.
      return tag[1].isEmpty ? null : tag[1];
    }
  }
  return null;
}

String? _asString(Object? value) => value is String ? value : null;

Map<String, dynamic>? _tryDecodeJsonMap(String content) {
  try {
    final decoded = jsonDecode(content);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
