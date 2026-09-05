import { ShieldCheck } from "lucide-react";

import type { ActiveAppSandbox } from "@/features/apps/appSandboxStore";

/**
 * Iframe `sandbox` for agent-authored HTML. `allow-scripts` only: no
 * `allow-same-origin` (opaque origin), no top navigation, no popups, no
 * downloads, no forms. This attribute survives any in-frame navigation, so it
 * holds even if the document's own CSP is gone — the second of the three
 * isolation layers (response CSP, this attribute, the native navigation lock).
 */
export const APP_SANDBOX_FLAGS = "allow-scripts";

export function appSandboxSrc(sha256: string): string {
  return `buzz-media://localhost/app/${sha256}.html`;
}

/**
 * Body of the app drawer: a provenance strip the app cannot draw over, and
 * the sandboxed iframe filling the rest. Mounted only while the drawer is
 * open, so closing the drawer destroys the frame and stops its scripts.
 */
export function AppSandboxPanel({ app }: { app: ActiveAppSandbox }) {
  return (
    <div
      className="-mx-4 -mb-8 flex h-full min-h-0 flex-col"
      data-testid="app-sandbox-panel"
    >
      <div className="flex shrink-0 items-center gap-2 border-b border-border/70 bg-muted/40 px-3 py-1.5 text-xs text-muted-foreground">
        <ShieldCheck className="h-3.5 w-3.5 shrink-0" aria-hidden />
        <span className="truncate">
          {app.sharedBy ? `App shared by ${app.sharedBy}` : "Shared app"} ·
          running in a sandbox (no network, no access to Buzz)
        </span>
      </div>
      <iframe
        allow=""
        className="min-h-0 flex-1 w-full border-0 bg-background"
        data-testid="app-sandbox-frame"
        referrerPolicy="no-referrer"
        sandbox={APP_SANDBOX_FLAGS}
        src={appSandboxSrc(app.sha256)}
        title={app.filename}
      />
    </div>
  );
}
