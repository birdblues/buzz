import * as React from "react";

/** The app currently open in the auxiliary drawer, if any. */
export type ActiveAppSandbox = {
  sha256: string;
  filename: string;
  /** Display label of the sender, for the drawer's provenance strip. */
  sharedBy?: string;
};

let active: ActiveAppSandbox | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Open `app` in the drawer. One app at a time: this replaces any other. */
export function openAppSandbox(app: ActiveAppSandbox): void {
  active = app;
  notify();
}

export function closeAppSandbox(): void {
  if (!active) return;
  active = null;
  notify();
}

export function useActiveAppSandbox(): ActiveAppSandbox | null {
  return React.useSyncExternalStore(
    subscribe,
    () => active,
    () => null,
  );
}

/** Community switch: never carry a running app across relays. */
export function resetAppSandboxStore(): void {
  active = null;
  notify();
}
