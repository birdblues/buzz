/**
 * What the app does when the backend reports that a managed-agent harness
 * exited (`managed-agent-runtime-status` with `exitCause`).
 *
 * Policy, mirrored from `managed_agents/reaper.rs`:
 *  - `crash`        → toast (aggregated) + cache refresh
 *  - `intentional`  → cache refresh only
 *  - `unknown`      → cache refresh only; the card badge carries `lastError`
 *
 * Toasts are fenced to the active community: `<Toaster />` mounts outside the
 * community remount boundary, so an unfenced toast would name another
 * community's agent over whichever community is on screen.
 *
 * Pure so the whole decision is testable against the exact JSON the Rust
 * side serializes.
 */

import { canonicalRelayUrl } from "@/features/agents/managedAgentRuntimeStatus";
import type { ManagedAgentRuntimeStatus } from "@/shared/api/types";
import { truncatePubkey } from "@/shared/lib/pubkey";

export type HarnessExitPayload = Pick<
  ManagedAgentRuntimeStatus,
  "pubkey" | "relayUrl" | "error" | "exitCause"
>;

export type HarnessExitAction = "ignore" | "refresh" | "notify";

/**
 * `ignore` for every status that is not an exit (start, stop, observer
 * lifecycle frames share the event). `notify` only for a crash in the active
 * community; everything else refreshes caches without a toast.
 */
export function harnessExitAction(
  payload: HarnessExitPayload,
  activeRelayUrl: string | null,
): HarnessExitAction {
  if (payload.exitCause == null) return "ignore";
  if (payload.exitCause !== "crash") return "refresh";
  if (activeRelayUrl === null) return "refresh";
  const active = canonicalRelayUrl(activeRelayUrl);
  const exited = canonicalRelayUrl(payload.relayUrl);
  if (active === null || exited === null || active !== exited) return "refresh";
  return "notify";
}

export type HarnessExitEntry = { name: string; error: string | null };

/** One toast for however many harnesses died in the same window. */
export function harnessExitToastCopy(
  entries: readonly HarnessExitEntry[],
): string {
  if (entries.length === 1) {
    const [{ name, error }] = entries;
    return error
      ? `${name} stopped unexpectedly: ${error}`
      : `${name} stopped unexpectedly.`;
  }
  const names = entries.map((entry) => entry.name).join(", ");
  return `${entries.length} agents stopped unexpectedly: ${names}. Open Agents for details.`;
}

/** How long crash reports are collected before one toast is shown. */
export const HARNESS_EXIT_TOAST_WINDOW_MS = 1_000;

export type HarnessExitHandlerDeps = {
  /** Active community relay at the moment the event arrives. */
  activeRelayUrl: () => string | null;
  /** Agent display name for a pubkey, or null when unknown. */
  agentName: (pubkey: string) => string | null;
  /** Drop the "working" badge for the dead pair. */
  clearActiveTurns: (pubkey: string, relayUrl: string) => void;
  /** Refresh the agent caches. */
  invalidate: () => void;
  /** Show the aggregated toast. */
  toast: (copy: string) => void;
  /** Timer seam; defaults to `setTimeout`. */
  schedule?: (fn: () => void, ms: number) => void;
};

/**
 * Stateful handler for one listener lifetime. Call `handle` per event;
 * crashes within [[HARNESS_EXIT_TOAST_WINDOW_MS]] coalesce into one toast.
 */
export function createHarnessExitHandler(deps: HarnessExitHandlerDeps): {
  handle: (payload: HarnessExitPayload) => HarnessExitAction;
  /** Cancel a pending toast (listener teardown). */
  dispose: () => void;
} {
  const schedule = deps.schedule ?? ((fn, ms) => setTimeout(fn, ms));
  let pending: HarnessExitEntry[] = [];
  let armed = false;
  let disposed = false;

  const flush = () => {
    armed = false;
    if (disposed || pending.length === 0) return;
    const batch = pending;
    pending = [];
    deps.toast(harnessExitToastCopy(batch));
  };

  return {
    handle(payload) {
      const action = harnessExitAction(payload, deps.activeRelayUrl());
      if (action === "ignore") return action;
      deps.clearActiveTurns(payload.pubkey, payload.relayUrl);
      deps.invalidate();
      if (action === "notify") {
        pending.push({
          name:
            deps.agentName(payload.pubkey) ?? truncatePubkey(payload.pubkey),
          error: payload.error,
        });
        if (!armed) {
          armed = true;
          schedule(flush, HARNESS_EXIT_TOAST_WINDOW_MS);
        }
      }
      return action;
    },
    dispose() {
      disposed = true;
      pending = [];
    },
  };
}
