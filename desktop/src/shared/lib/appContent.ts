import * as React from "react";

import { invokeTauri } from "@/shared/api/tauri";

/**
 * Whether the active relay advertises a sandboxed app-content door (NIP-11
 * `app_content_url`). Resolved once per community through the native side,
 * which owns the discovery cache and the URL validation; the frontend only
 * learns a boolean so it never handles the app origin or a token.
 *
 * Unknown (not yet asked) reads as `false`: HTML attachments stay download
 * cards until the answer arrives, never the other way round.
 */
let available = false;
let pending: Promise<void> | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  for (const listener of listeners) listener();
}

function ensureFetch(): void {
  if (pending) return;
  pending = invokeTauri<boolean>("app_content_available")
    .then((result) => {
      available = result === true;
    })
    .catch(() => {
      available = false;
    })
    .finally(notify);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  ensureFetch();
  return () => {
    listeners.delete(listener);
  };
}

function getSnapshot(): boolean {
  return available;
}

/** React hook: `true` once the relay is known to serve sandboxed apps. */
export function useAppContentAvailable(): boolean {
  return React.useSyncExternalStore(subscribe, getSnapshot, () => false);
}

/** Community switch: forget the answer and let the next reader re-ask. */
export function resetAppContentAvailability(): void {
  available = false;
  pending = null;
  void invokeTauri("reset_app_content_discovery").catch(() => {});
  notify();
}
