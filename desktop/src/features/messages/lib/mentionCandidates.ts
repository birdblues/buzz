import { resolveTeamPersonas } from "@/features/agents/lib/teamPersonas";
import type {
  AgentPersona,
  AgentTeam,
  ChannelRole,
  UserSearchResult,
} from "@/shared/api/types";
import { truncatePubkey } from "@/shared/lib/pubkey";

export function formatSearchUserDisplayName(user: UserSearchResult) {
  return user.displayName?.trim() || user.nip05Handle?.trim() || null;
}

export function formatSearchUserSecondaryLabel(user: UserSearchResult) {
  const displayName = user.displayName?.trim();
  const nip05Handle = user.nip05Handle?.trim();
  return displayName && nip05Handle ? nip05Handle : null;
}

export function appendUniqueName(current: string[], name: string): string[] {
  return current.some(
    (candidate) => candidate.toLowerCase() === name.toLowerCase(),
  )
    ? current
    : [...current, name];
}

export type TeamMentionMember = {
  displayName: string;
  kind: "identity" | "persona";
  personaId?: string;
  pubkey?: string;
};

export type MentionCandidate = {
  kind: "identity" | "persona" | "team";
  pubkey?: string;
  personaId?: string;
  teamId?: string;
  teamMembers?: TeamMentionMember[];
  displayName: string | null;
  avatarUrl?: string | null;
  isMember: boolean;
  role?: ChannelRole | null;
  personaName?: string | null;
  secondaryLabel?: string | null;
  ownerPubkey?: string | null;
  isAgent: boolean;
  isActiveAgent?: boolean;
  isManagedAgent?: boolean;
  isGlobalSearchResult?: boolean;
};

export function mentionCandidateLabel(candidate: MentionCandidate) {
  return (
    candidate.displayName ??
    (candidate.pubkey ? truncatePubkey(candidate.pubkey) : "agent")
  );
}

export function globalSearchIdentityKey(candidate: MentionCandidate) {
  if (
    !candidate.isGlobalSearchResult ||
    candidate.isMember ||
    candidate.isAgent
  ) {
    return null;
  }

  const label = candidate.displayName?.trim().toLowerCase();
  if (!label) return null;

  const secondaryLabel = candidate.secondaryLabel?.trim().toLowerCase() ?? "";
  return `global-person:${label}:${secondaryLabel}`;
}

function isOtherOwnersIdentity(
  candidate: MentionCandidate,
  currentPubkey: string | null,
): boolean {
  if (candidate.kind !== "identity" || !candidate.ownerPubkey) return false;
  return (
    currentPubkey === null ||
    candidate.ownerPubkey.toLowerCase() !== currentPubkey.toLowerCase()
  );
}

function findTeamMemberTarget(
  persona: AgentPersona,
  candidates: readonly MentionCandidate[],
  ownedPersonaIds: ReadonlySet<string>,
  currentPubkey: string | null,
): TeamMentionMember | null {
  const linked = candidates
    .filter(
      (candidate) =>
        candidate.kind !== "team" &&
        candidate.personaId === persona.id &&
        // Defence in depth over the owner filter applied where the link is
        // read: an identity whose verified owner is somebody else must never
        // stand in for our team's member, because builtin definition ids are
        // identical across owners. An identity with no verified owner keeps
        // its existing treatment — it can only carry a definition id that
        // came from our own local store.
        !isOtherOwnersIdentity(candidate, currentPubkey),
    )
    .sort((left, right) => {
      const rank = (candidate: MentionCandidate) => {
        if (candidate.kind === "identity" && candidate.isMember) return 0;
        if (candidate.kind === "identity" && candidate.isManagedAgent) return 1;
        if (candidate.kind === "identity") return 2;
        return 3;
      };
      return rank(left) - rank(right);
    })[0];

  // An identity addresses an agent that already exists; nothing is minted.
  if (linked?.kind === "identity") {
    return {
      displayName: linked.displayName?.trim() || persona.displayName,
      kind: "identity",
      personaId: linked.personaId,
      pubkey: linked.pubkey,
    };
  }

  if (!persona.isActive) return null;

  // Everything below resolves to a persona member, and sending one MINTS a
  // new local agent identity. That is only correct when this definition has
  // no instance of ours anywhere — otherwise the new identity answers every
  // message twice alongside the instance already running on another device.
  // `remoteOrigin` covers definitions that arrived by sync; `ownedPersonaIds`
  // additionally covers a locally authored (or builtin) definition whose only
  // instance lives elsewhere, which carries no such marker. The launcher
  // candidate `linked` may point at here too, so this gate has to sit after
  // it rather than only on the no-candidate path.
  if (persona.remoteOrigin || ownedPersonaIds.has(persona.id)) return null;

  return {
    displayName: linked?.displayName?.trim() || persona.displayName,
    kind: "persona",
    personaId: linked?.personaId ?? persona.id,
  };
}

/** Build autocomplete entries for editable, locally owned teams. */
export function buildTeamMentionCandidates(
  teams: readonly AgentTeam[],
  personas: AgentPersona[],
  candidates: readonly MentionCandidate[],
  /**
   * Definition ids that already have an instance owned by the current user,
   * including instances that run on another device and instances outside this
   * channel. Used only to refuse minting a duplicate — never to mention one.
   */
  ownedPersonaIds: ReadonlySet<string> = new Set(),
  currentPubkey: string | null = null,
): MentionCandidate[] {
  return teams.flatMap((team) => {
    if (team.isBuiltin || !team.name.trim()) return [];

    const resolution = resolveTeamPersonas(team, personas);
    if (!resolution.isUsable) return [];

    const teamMembers = resolution.resolvedPersonas
      .map((persona) =>
        findTeamMemberTarget(
          persona,
          candidates,
          ownedPersonaIds,
          currentPubkey,
        ),
      )
      .filter((member): member is TeamMentionMember => member !== null);
    if (teamMembers.length !== resolution.resolvedPersonas.length) return [];

    const mentionNames = new Set<string>();
    for (const member of teamMembers) {
      const mentionName = member.displayName.trim().toLowerCase();
      if (mentionNames.has(mentionName)) return [];
      mentionNames.add(mentionName);
    }

    return [
      {
        kind: "team" as const,
        teamId: team.id,
        teamMembers,
        displayName: team.name.trim(),
        isMember: false,
        isAgent: true,
      },
    ];
  });
}

export function formatTeamMention(
  teamName: string,
  members: readonly TeamMentionMember[],
) {
  return `${teamName}(${members.map((member) => `@${member.displayName}`).join(" ")}) `;
}
