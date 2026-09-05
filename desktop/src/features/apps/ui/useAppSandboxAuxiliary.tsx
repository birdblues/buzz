import * as React from "react";

import {
  closeAppSandbox,
  useActiveAppSandbox,
} from "@/features/apps/appSandboxStore";
import { AppSandboxPanel } from "@/features/apps/ui/AppSandboxPanel";

/**
 * The idle-auxiliary props a channel host should spread when an app is
 * open. Apps ride the same auxiliary surface as threads and workspace
 * sheets, so they inherit the drawer/docked placement and animation for
 * free; `idleAuxiliaryOverridesThread` puts the app above an open thread.
 */
export type AppSandboxAuxiliaryProps = {
  idleAuxiliaryPanel: React.ReactNode;
  idleAuxiliaryTitle: string;
  idleAuxiliaryOverridesThread: boolean;
  onCloseIdleAuxiliaryPanel: () => void;
};

export function useAppSandboxAuxiliary(): AppSandboxAuxiliaryProps | null {
  const app = useActiveAppSandbox();
  return React.useMemo(() => {
    if (!app) return null;
    return {
      idleAuxiliaryPanel: <AppSandboxPanel app={app} />,
      idleAuxiliaryTitle: app.filename,
      idleAuxiliaryOverridesThread: true,
      onCloseIdleAuxiliaryPanel: closeAppSandbox,
    };
  }, [app]);
}
