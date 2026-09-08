part of '../compose_bar.dart';

class _SendButton extends StatelessWidget {
  final bool isSending;
  final bool isDisabled;
  final VoidCallback onTap;

  const _SendButton({
    required this.isSending,
    required this.onTap,
    this.isDisabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        onPressed: (isSending || isDisabled)
            ? null
            : () => _runComposerAction(onTap),
        style: IconButton.styleFrom(
          backgroundColor: context.colors.primary,
          disabledBackgroundColor: context.colors.primary.withValues(
            alpha: 0.5,
          ),
          shape: const CircleBorder(),
        ),
        padding: EdgeInsets.zero,
        icon: isSending
            ? BuzzLoadingIndicator(
                size: 18,
                color: context.colors.onPrimary,
                semanticLabel: 'Sending message',
              )
            : Icon(
                LucideIcons.arrowUp,
                size: 18,
                color: context.colors.onPrimary,
              ),
      ),
    );
  }
}

/// The line the composer shows under a failed attachment.
///
/// Our own upload exceptions already read as sentences. Anything else is
/// either an `Exception` whose message was written for a person, or something
/// with no message for one at all — a platform error naming a code and a mime
/// type, say — and those get a plain line while the original goes to the log.
String _formatUploadError(Object error) {
  if (error is MediaPolicyUploadException ||
      error is MediaPreparationException) {
    return error.toString();
  }
  if (error is Exception && error is! PlatformException) {
    return error.toString().replaceFirst('Exception: ', '');
  }
  debugPrint('[ComposeBar] attachment failed: $error');
  return 'Something went wrong with this attachment. Try again.';
}
