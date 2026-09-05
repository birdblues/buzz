import * as React from "react";

import {
  ForumView,
  UserProfilePanel,
} from "@/features/channels/ui/ChannelScreenLazyViews";
import {
  IdleAuxiliaryPanel,
  type IdleAuxiliaryHeaderControls,
} from "@/features/channels/ui/IdleAuxiliaryPanel";
import { RightAuxiliaryPane } from "@/features/channels/ui/RightAuxiliaryPane";
import type {
  ProfilePanelTab,
  ProfilePanelView,
} from "@/features/profile/ui/UserProfilePanelUtils";
import type { Channel } from "@/shared/api/types";
import type { ProfilePanelOpenOptions } from "@/shared/context/ProfilePanelContext";
import { ViewLoadingFallback } from "@/shared/ui/ViewLoadingFallback";

type ForumChannelContentProps = {
  canResetPanelWidth: boolean;
  channel: Channel;
  currentPubkey?: string;
  header: React.ReactNode;
  /**
   * Idle auxiliary content (the sandboxed-app drawer, `useAppSandboxAuxiliary`)
   * and its chrome. ChannelPane hosts the same props for message channels;
   * forums replace ChannelPane, so without a host here an app's Run button
   * would set store state that never renders.
   */
  idleAuxiliaryHeaderActions?: IdleAuxiliaryHeaderControls;
  idleAuxiliaryPanel?: React.ReactNode;
  idleAuxiliaryTitle?: string;
  onCloseIdleAuxiliaryPanel?: () => void;
  onClosePost: () => void;
  onCloseProfilePanel: () => void;
  onOpenDm?: (pubkeys: string[]) => Promise<void> | void;
  onOpenProfilePanel: (
    pubkey: string,
    options?: ProfilePanelOpenOptions,
  ) => void;
  onPanelResizeStart: (event: React.PointerEvent<HTMLButtonElement>) => void;
  onProfilePanelTabChange: (
    tab: ProfilePanelTab,
    options?: { replace?: boolean },
  ) => void;
  onProfilePanelViewChange: (
    view: ProfilePanelView,
    options?: { replace?: boolean },
  ) => void;
  onResetPanelWidth: () => void;
  onSelectPost: (postId: string) => void;
  panelWidthPx: number;
  profilePanelPubkey?: string | null;
  profilePanelTab: ProfilePanelTab;
  profilePanelView: ProfilePanelView;
  selectedPostId: string | null;
  targetReplyId: string | null;
  targetSearchMessageId?: string;
  targetSearchQuery?: string;
};

/**
 * Forum-channel body for ChannelScreen: the post list/thread plus the
 * user-profile auxiliary pane. Forums replace ChannelPane (which hosts the
 * profile panel for message channels), so without this host, opening a
 * profile from a mention chip, avatar, or the members sidebar would set
 * state that never renders.
 */
export function ForumChannelContent({
  canResetPanelWidth,
  channel,
  currentPubkey,
  header,
  idleAuxiliaryHeaderActions,
  idleAuxiliaryPanel = null,
  idleAuxiliaryTitle = "",
  onCloseIdleAuxiliaryPanel,
  onClosePost,
  onCloseProfilePanel,
  onOpenDm,
  onOpenProfilePanel,
  onPanelResizeStart,
  onProfilePanelTabChange,
  onProfilePanelViewChange,
  onResetPanelWidth,
  onSelectPost,
  panelWidthPx,
  profilePanelPubkey,
  profilePanelTab,
  profilePanelView,
  selectedPostId,
  targetReplyId,
  targetSearchMessageId,
  targetSearchQuery,
}: ForumChannelContentProps) {
  return (
    <>
      {header}
      <div className="flex min-h-0 min-w-0 flex-1 flex-row overflow-hidden">
        <section
          aria-label="Forum posts"
          className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden"
        >
          <React.Suspense fallback={<ViewLoadingFallback kind="forum" />}>
            <ForumView
              channel={channel}
              currentPubkey={currentPubkey}
              onClosePost={onClosePost}
              onSelectPost={onSelectPost}
              selectedPostId={selectedPostId}
              targetReplyId={targetReplyId}
              targetSearchMessageId={targetSearchMessageId}
              targetSearchQuery={targetSearchQuery}
            />
          </React.Suspense>
        </section>
        {idleAuxiliaryPanel && onCloseIdleAuxiliaryPanel ? (
          // An open app takes the auxiliary column, as it overrides an open
          // thread in ChannelPane; the profile panel returns when it closes.
          <IdleAuxiliaryPanel
            canResetWidth={canResetPanelWidth}
            headerControls={idleAuxiliaryHeaderActions}
            isSinglePanelView={false}
            onClose={onCloseIdleAuxiliaryPanel}
            onResetWidth={onResetPanelWidth}
            onResizeStart={onPanelResizeStart}
            title={idleAuxiliaryTitle}
            useSplitAuxiliaryPane={false}
            widthPx={panelWidthPx}
          >
            {idleAuxiliaryPanel}
          </IdleAuxiliaryPanel>
        ) : profilePanelPubkey ? (
          <RightAuxiliaryPane
            canResetWidth={canResetPanelWidth}
            onResetWidth={onResetPanelWidth}
            onResizeStart={onPanelResizeStart}
            testId="user-profile-panel"
            widthPx={panelWidthPx}
          >
            <React.Suspense fallback={null}>
              <UserProfilePanel
                currentPubkey={currentPubkey}
                isSinglePanelView={false}
                layout="split"
                onClose={onCloseProfilePanel}
                onOpenDm={onOpenDm}
                onOpenProfile={onOpenProfilePanel}
                onTabChange={onProfilePanelTabChange}
                onViewChange={onProfilePanelViewChange}
                pubkey={profilePanelPubkey}
                splitPaneClamp
                tab={profilePanelTab}
                view={profilePanelView}
                widthPx={panelWidthPx}
              />
            </React.Suspense>
          </RightAuxiliaryPane>
        ) : null}
      </div>
    </>
  );
}
