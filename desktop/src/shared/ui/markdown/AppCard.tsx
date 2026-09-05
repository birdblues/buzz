import * as React from "react";
import { AppWindow, Download, Play } from "lucide-react";
import { toast } from "sonner";

import { openAppSandbox } from "@/features/apps/appSandboxStore";
import { invokeTauri } from "@/shared/api/tauri";
import { useTheme } from "@/shared/theme/ThemeProvider";
import { useSmoothCorners } from "@/shared/ui/smoothCorners";

function formatFileSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let size = bytes / 1024;
  let i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i += 1;
  }
  return `${size < 10 ? size.toFixed(1) : Math.round(size)} ${units[i]}`;
}

/**
 * Card for a sandboxed HTML app attachment. Shows a static, theme-matched
 * preview (a plain image — nothing here can run script) and two actions:
 * **Run**, which opens the app in the auxiliary drawer, and **Download**.
 * Never auto-runs.
 */
export function AppCard({
  sha256,
  filename,
  size,
  downloadHref,
  previewLight,
  previewDark,
  sharedBy,
}: {
  sha256: string;
  filename: string;
  size?: number;
  downloadHref: string;
  previewLight?: string;
  previewDark?: string;
  sharedBy?: string;
}) {
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  useSmoothCorners(cardRef);
  const { isDark } = useTheme();
  const preview =
    (isDark ? previewDark : previewLight) ?? previewLight ?? previewDark;
  const sizeLabel = size != null ? formatFileSize(size) : "";

  return (
    <div
      ref={cardRef}
      data-testid="app-card"
      className="my-1 flex w-full max-w-md flex-col overflow-hidden rounded-2xl border border-border/70 bg-muted/40"
      style={{ borderRadius: "1rem" }}
    >
      {preview ? (
        <button
          type="button"
          aria-label={`Run ${filename}`}
          className="block w-full bg-background"
          onClick={() => openAppSandbox({ sha256, filename, sharedBy })}
        >
          <img
            alt={`Preview of ${filename}`}
            className="block max-h-64 w-full object-contain"
            decoding="async"
            draggable={false}
            loading="lazy"
            src={preview}
          />
        </button>
      ) : null}
      <div className="flex items-center gap-3 px-3 py-2">
        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-background text-muted-foreground">
          <AppWindow className="h-4 w-4" />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-medium text-foreground">
            {filename}
          </span>
          <span className="block truncate text-xs text-muted-foreground">
            {sharedBy ? `App shared by ${sharedBy}` : "Shared app"}
            {sizeLabel ? ` · ${sizeLabel}` : ""} · runs in a sandbox
          </span>
        </span>
        <button
          type="button"
          data-testid="app-card-run"
          className="inline-flex h-8 shrink-0 items-center gap-1 rounded-lg bg-primary px-3 text-xs font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          onClick={() => openAppSandbox({ sha256, filename, sharedBy })}
        >
          <Play className="h-3.5 w-3.5" />
          Run
        </button>
        <button
          type="button"
          aria-label={`Download ${filename}`}
          data-testid="app-card-download"
          className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-muted/70 hover:text-foreground"
          onClick={() => {
            invokeTauri("download_file", { url: downloadHref, filename }).catch(
              (err: unknown) => {
                const msg =
                  err instanceof Error ? err.message : "Download failed";
                toast.error(msg);
              },
            );
          }}
        >
          <Download className="h-4 w-4" />
        </button>
      </div>
    </div>
  );
}
