part of '../compose_bar.dart';

Future<void> _sendTextOnlyDraft({
  required BuildContext context,
  required _MarkdownEditingController controller,
  required ObjectRef<Map<String, MentionCandidate>> mentionMap,
  required ObjectRef<int> draftRevision,
  required int submittedDraftRevision,
  required FocusNode focusNode,
  required VoidCallback clearComposer,
  required Future<void> Function() addMentionedNonMembers,
  required _ComposeDraftPayload payload,
  required _OutgoingMentions outgoing,
  required ComposeBarOnSend onSend,
  required ScaffoldMessengerState? messenger,
  required VoidCallback onRestoreDraft,
}) async {
  TextEditingValue? clearedDraftText;
  Map<String, MentionCandidate>? clearedDraftMentions;
  int? clearedDraftRevision;

  void restoreClearedDraft() {
    if (!context.mounted ||
        clearedDraftText == null ||
        clearedDraftMentions == null ||
        clearedDraftRevision == null ||
        draftRevision.value != clearedDraftRevision) {
      return;
    }
    controller.value = clearedDraftText;
    mentionMap.value
      ..clear()
      ..addAll(clearedDraftMentions);
    onRestoreDraft();
    focusNode.requestFocus();
  }

  try {
    await addMentionedNonMembers();
    // Clear before optimistic insertion so the outgoing row and draft never
    // appear simultaneously during the send transition. If the user edited
    // while membership changes were pending, preserve that newer draft.
    if (context.mounted && draftRevision.value == submittedDraftRevision) {
      clearedDraftText = controller.value;
      clearedDraftMentions = Map<String, MentionCandidate>.of(mentionMap.value);
      clearComposer();
      clearedDraftRevision = draftRevision.value;
    }
    await onSend(
      payload.content,
      outgoing.pubkeys,
      mediaTags: [...payload.mediaTags, ...outgoing.referenceTags],
    );
  } on StateError {
    restoreClearedDraft();
    _reportSendCancelledByCommunitySwitch(messenger);
  } catch (error) {
    // The caller runs unawaited, so surface publish failures and restore the
    // sent draft unless the user has already started a new one.
    restoreClearedDraft();
    showSnackBarIfPresentable(
      messenger,
      SnackBar(content: Text(_composeSendErrorMessage(error))),
    );
  }
}

void _useComposeDraftLifecycle({
  required WidgetRef ref,
  required _MarkdownEditingController controller,
  required String draftKey,
  required String channelId,
  required String? threadHeadId,
  required String draftIdentity,
  required ObjectRef<int> draftRevision,
  required ValueNotifier<List<_PendingAttachment>> attachments,
  required ObjectRef<int> uploadGeneration,
  required ObjectRef<UploadCancellationToken?> activeUploadCancellation,
  required ValueNotifier<int> uploadingCount,
  required ValueNotifier<bool> isSending,
  required ValueNotifier<_AttachmentSurface> attachmentSurface,
  required ValueNotifier<String?> uploadError,
  required _IOSAttachmentPopoverController iosAttachmentPopover,
  required VoidCallback onDraftIdentityChanged,
}) {
  final lastDraftIdentity = useRef<String?>(null);
  useEffect(() {
    final identityChanged =
        lastDraftIdentity.value != null &&
        lastDraftIdentity.value != draftIdentity;
    lastDraftIdentity.value = draftIdentity;
    final saved = ref.read(composeDraftsProvider.notifier).textFor(draftKey);
    if (identityChanged) {
      draftRevision.value += 1;
      onDraftIdentityChanged();
      uploadGeneration.value += 1;
      activeUploadCancellation.value?.cancel();
      activeUploadCancellation.value = null;
      uploadingCount.value = 0;
      isSending.value = false;
      attachmentSurface.value = _AttachmentSurface.closed;
      uploadError.value = null;
      unawaited(iosAttachmentPopover.dispose());
      final staleAttachments = attachments.value;
      attachments.value = const [];
      unawaited(_deleteOwnedAttachments(staleAttachments));
      controller.text = saved ?? '';
    } else if (saved != null && controller.text.isEmpty) {
      controller.text = saved;
    }

    var lastPersistedText = controller.text;
    void persistDraft() {
      final text = controller.text;
      if (text == lastPersistedText) return;
      lastPersistedText = text;
      draftRevision.value += 1;
      ref
          .read(composeDraftsProvider.notifier)
          .save(
            key: draftKey,
            channelId: channelId,
            threadHeadId: threadHeadId,
            text: text,
          );
    }

    controller.addListener(persistDraft);
    return () => controller.removeListener(persistDraft);
  }, [controller, draftKey, draftIdentity, onDraftIdentityChanged]);
}

/// A sandboxed app asked to talk to the agent (`sandbox_bridge.dart`). The
/// merged draft is already persisted for this composer; show it, open the
/// editor and hand it the caret. Nothing is sent — the user does that.
void _listenForComposerPrefill({
  required WidgetRef ref,
  required _MarkdownEditingController controller,
  required String draftKey,
  required ObjectRef<bool> isModifyingText,
  required ObjectRef<TextEditingValue> lastObservedEditingValue,
  required ValueNotifier<bool> isExpanded,
  required FocusNode focusNode,
  required VoidCallback expandComposer,
}) {
  ref.listen<ComposerPrefill?>(composerPrefillProvider, (_, prefill) {
    if (prefill == null || prefill.key != draftKey) return;
    if (controller.text != prefill.text) {
      // Not a keystroke: skip the mention/typing listener the way
      // formatting inserts do, then let it observe the new value.
      isModifyingText.value = true;
      try {
        controller.value = TextEditingValue(
          text: prefill.text,
          selection: TextSelection.collapsed(offset: prefill.text.length),
        );
      } finally {
        isModifyingText.value = false;
      }
      lastObservedEditingValue.value = controller.value;
    }
    final wasExpanded = isExpanded.value;
    expandComposer();
    if (wasExpanded) focusNode.requestFocus();
  });
}
