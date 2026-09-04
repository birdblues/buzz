import * as React from "react";

import { useRelayAgentsQuery } from "@/features/agents/hooks";
import { useIsArchivedPredicate } from "@/features/identity-archive/hooks";
import { useIdentityQuery } from "@/shared/api/hooks";
import type { ManagedAgent, RelayAgent } from "@/shared/api/types";
import { normalizePubkey } from "@/shared/lib/pubkey";

/**
 * Definitions that already have an instance the viewer owns, from BOTH the
 * local store and the relay directory. The relay half is what makes this
 * useful: it reports our agents even when they run on another device or sit
 * outside the current channel, which is exactly the state `remoteOrigin`
 * cannot describe (a locally authored or builtin definition carries no
 * provenance marker even when its only body lives elsewhere).
 *
 * Pure so the whole decision is testable without a relay or a React tree.
 */
export function collectOwnedPersonaIds({
  currentPubkey,
  isArchived,
  managedAgentPersonaIds,
  relayAgents,
}: {
  currentPubkey: string | null | undefined;
  isArchived: (pubkey: string) => boolean;
  managedAgentPersonaIds: Iterable<string>;
  relayAgents: readonly RelayAgent[] | undefined;
}): ReadonlySet<string> {
  const owned = new Set(managedAgentPersonaIds);
  const viewer = currentPubkey?.toLowerCase() ?? null;
  if (viewer === null) return owned;
  for (const agent of relayAgents ?? []) {
    if (!agent.personaId) continue;
    // An archived instance is retired, not running — it must not suppress the
    // definition, or an archive-only definition becomes unusable with no way
    // back.
    if (isArchived(agent.pubkey)) continue;
    // A builtin definition id is identical across owners, so the persona id
    // alone cannot establish ownership — another owner's agent must never
    // suppress ours.
    if (agent.ownerPubkey?.toLowerCase() === viewer) {
      owned.add(agent.personaId);
    }
  }
  return owned;
}

/**
 * Why a definition may not be given another identity on this device, or
 * `undefined` when it may.
 *
 * Mirrors the backend refusal in `ensure_persona_not_remote_origin`, and adds
 * the case that refusal cannot see: a definition with no `remoteOrigin` marker
 * whose only instance runs on another device. Wording matches the backend so
 * both boundaries read the same.
 */
export function personaStartBlockReason(
  persona: { displayName: string; id: string; remoteOrigin?: boolean },
  /**
   * Ids owned ELSEWHERE — never the union that includes local instances. A
   * definition with a local instance is a different situation (that Start
   * resumes the instance rather than minting) and must not be refused here.
   */
  personaIdsOwnedElsewhere: ReadonlySet<string>,
): string | undefined {
  if (!persona.remoteOrigin && !personaIdsOwnedElsewhere.has(persona.id)) {
    return undefined;
  }
  return `${persona.displayName} is already set up on another device and answers from there. Duplicate it to run a separate copy here.`;
}

/** Persona ids of the viewer's own local instances. */
export function localManagedAgentPersonaIds(
  managedAgents: readonly ManagedAgent[] | undefined,
): ReadonlySet<string> {
  const ids = new Set<string>();
  for (const agent of managedAgents ?? []) {
    if (agent.personaId) ids.add(agent.personaId);
  }
  return ids;
}

/**
 * Surface-owned reader for [[collectOwnedPersonaIds]]. Every creation
 * affordance that mints a NEW identity for a definition consults this, so the
 * card, the profile panel and the mention launcher all answer the same
 * question from the same data.
 *
 * Fail-open by construction: an unloaded or failed directory yields only the
 * local half, so the affordance behaves exactly as it did before this signal
 * existed rather than disappearing while offline.
 */
export function useOwnedPersonaIds(
  managedAgents: readonly ManagedAgent[] | undefined,
): {
  /** Local instances plus relay-reported ones. */
  owned: ReadonlySet<string>;
  /** Owned on the relay with no local instance — the creation gate's input. */
  ownedElsewhere: ReadonlySet<string>;
} {
  const relayAgentsQuery = useRelayAgentsQuery();
  const identityQuery = useIdentityQuery();
  const isArchived = useIsArchivedPredicate();
  const currentPubkey = identityQuery.data?.pubkey
    ? normalizePubkey(identityQuery.data.pubkey)
    : null;
  const relayAgents = relayAgentsQuery.data;
  return React.useMemo(() => {
    const local = localManagedAgentPersonaIds(managedAgents);
    const owned = collectOwnedPersonaIds({
      currentPubkey,
      isArchived,
      managedAgentPersonaIds: local,
      relayAgents,
    });
    const ownedElsewhere = new Set<string>();
    for (const id of owned) {
      if (!local.has(id)) ownedElsewhere.add(id);
    }
    return { owned, ownedElsewhere };
  }, [currentPubkey, isArchived, managedAgents, relayAgents]);
}
