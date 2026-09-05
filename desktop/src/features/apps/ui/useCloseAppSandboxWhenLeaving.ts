import * as React from "react";

import { closeAppSandbox } from "@/features/apps/appSandboxStore";

/**
 * Closes the open app when the surface it was opened from goes away.
 *
 * `scopeKey` names that surface — the channel on the channel route, the
 * channel plus selected post in a forum. Whenever it changes, or the host
 * unmounts, the drawer closes exactly as its own close button would, so an
 * app never follows the reader to another channel or another post.
 */
export function useCloseAppSandboxWhenLeaving(scopeKey: string): void {
  // biome-ignore lint/correctness/useExhaustiveDependencies: the key is the trigger — a change re-runs the cleanup — not a value the cleanup reads.
  React.useEffect(() => () => closeAppSandbox(), [scopeKey]);
}
