import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

const _maxMessageSnapshotDimension = 2048.0;

double _messageSnapshotPixelRatio(Size size, double devicePixelRatio) {
  final longestSide = size.longestSide;
  if (!longestSide.isFinite || longestSide <= 0) return devicePixelRatio;
  return math.min(devicePixelRatio, _maxMessageSnapshotDimension / longestSide);
}

/// Geometry and snapshot controls for a completed message activation gesture
/// (a double tap, or a long press on a non-text part of the row).
///
/// Call [captureSnapshot] while the source is still mounted, then use
/// [setSourceHidden] to hide it behind the lifted preview. Restore the source
/// before the preview is disposed or dismissed.
class MessageGestureDetails {
  /// The activated source bounds in global logical coordinates.
  final Rect anchorRect;

  /// Captures the current source as an image for the lifted preview.
  ///
  /// The returned future can fail if the source is no longer mounted.
  final Future<ui.Image> Function() captureSnapshot;

  /// Hides or reveals the mounted source while its preview is displayed.
  final ValueChanged<bool> setSourceHidden;

  /// Creates the details passed to a completed activation callback.
  const MessageGestureDetails({
    required this.anchorRect,
    required this.captureSnapshot,
    required this.setSourceHidden,
  });
}

// ---------------------------------------------------------------------------
// Single pending tap, app-wide.
//
// A row's single tap is deferred by [kDoubleTapTimeout] so a second tap can
// turn it into a double tap. Keeping one candidate for the whole app means a
// tap on another row, a nested control, or a scroll cancels the first tap
// instead of letting two deferred taps fire back to back.
// ---------------------------------------------------------------------------

class _PendingTap {
  _PendingTap({
    required this.owner,
    required this.position,
    required this.dismissOnly,
  });

  final Object owner;
  final Offset position;

  /// The tap only dismissed a text selection; its expiry must not run
  /// [MessageGestureInkWell.onTap]. A second tap still counts as a double tap.
  final bool dismissOnly;

  Timer? timer;
  bool secondDown = false;
  int? secondPointer;
}

_PendingTap? _pendingTap;

/// Cancels the single tap a message row is waiting to deliver, if any.
void cancelPendingMessageTap() {
  _pendingTap?.timer?.cancel();
  _pendingTap = null;
}

// ---------------------------------------------------------------------------
// Active text selection, app-wide (one message at a time, like iOS).
//
// Rows use a non-focusable focus node (so selecting never steals the
// composer's keyboard), which also disables Flutter's clear-on-blur. This
// registry is the explicit replacement.
// ---------------------------------------------------------------------------

GlobalKey<SelectionAreaState>? _activeSelectionKey;

void _clearSelectionOf(GlobalKey<SelectionAreaState>? key) {
  final state = key?.currentState;
  if (state == null || !state.mounted) return;
  final region = state.selectableRegion;
  region.hideToolbar();
  region.clearSelection();
}

/// Clears the active message text selection (highlight, handles, toolbar).
///
/// Returns true when a mounted selection existed.
bool dismissActiveMessageSelection() {
  final key = _activeSelectionKey;
  if (key == null) return false;
  // Drop the pointer first so the region's own `onSelectionChanged(null)`
  // re-entry sees no owner to clear.
  _activeSelectionKey = null;
  final state = key.currentState;
  if (state == null || !state.mounted) return false;
  _clearSelectionOf(key);
  return true;
}

/// Resets the app-wide tap and selection state between tests.
@visibleForTesting
void resetMessageGestureStateForTesting() {
  cancelPendingMessageTap();
  _activeSelectionKey = null;
}

/// Lets descendants of a message row (media previews, the author row) open
/// the row's action menu from their own long press, where there is no text
/// to select.
class MessageGestureScope extends InheritedWidget {
  /// Creates a scope publishing [openActions].
  const MessageGestureScope({
    super.key,
    required this.openActions,
    required super.child,
  });

  /// Opens the row's action menu (dismissing any text selection first).
  final VoidCallback openActions;

  /// The nearest scope, or null outside a message row.
  static MessageGestureScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessageGestureScope>();

  @override
  bool updateShouldNotify(MessageGestureScope oldWidget) =>
      openActions != oldWidget.openActions;
}

/// An [InkWell] for message rows: a double tap opens the row's actions, a
/// long press on body text starts a native text selection (word under the
/// finger, draggable handles, Copy toolbar), and a single tap is delivered
/// after [kDoubleTapTimeout] when no second tap follows.
///
/// Links, media, reactions, and other nested controls keep their normal tap
/// gestures. Long presses on non-text parts open the actions through
/// [MessageGestureScope].
class MessageGestureInkWell extends StatelessWidget {
  /// Single-tap callback, delivered once a double tap has been ruled out.
  final VoidCallback? onTap;

  /// Handles a double tap with the row's global bounds.
  final ValueChanged<Rect>? onDoubleTap;

  /// Handles a double tap with snapshot and source-visibility access.
  ///
  /// When provided, this callback takes precedence over [onDoubleTap].
  final ValueChanged<MessageGestureDetails>? onDoubleTapDetails;

  /// Whether a long press selects the row's text. Off for system rows.
  final bool selectable;

  /// Reports the row's text selection; null when it collapses.
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  final BorderRadius? borderRadius;
  final Color? highlightColor;

  /// Identifies the [RepaintBoundary] to capture for the lifted preview.
  ///
  /// The key's current context must resolve to a boundary covering the message
  /// content. When omitted, this widget inserts and owns that boundary.
  final GlobalKey? snapshotKey;
  final Widget child;

  const MessageGestureInkWell({
    super.key,
    this.onTap,
    this.onDoubleTap,
    this.onDoubleTapDetails,
    this.selectable = true,
    this.onSelectionChanged,
    this.borderRadius,
    this.highlightColor,
    this.snapshotKey,
    required this.child,
  }) : assert(onDoubleTap != null || onDoubleTapDetails != null);

  @override
  Widget build(BuildContext context) {
    return _MessageGestureRegion(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onDoubleTapDetails: onDoubleTapDetails,
      selectable: selectable,
      onSelectionChanged: onSelectionChanged,
      borderRadius: borderRadius,
      highlightColor: highlightColor,
      externalSnapshotKey: snapshotKey,
      child: child,
    );
  }
}

/// Gesture ownership, outermost first:
///
/// * `SelectionArea` — its long press selects the word under the finger; its
///   tap recognizer loses every plain tap to the deeper `InkWell`, so a
///   double tap never turns into a word selection.
/// * `Listener` — raw pointer events, outside the arena, used only to notice
///   a second press early and to drop a pending tap when the second press
///   turns into something else (drag, long press, nested control).
/// * `InkWell` — always has a tap handler so it is the deepest tap member.
class _MessageGestureRegion extends HookWidget {
  final VoidCallback? onTap;
  final ValueChanged<Rect>? onDoubleTap;
  final ValueChanged<MessageGestureDetails>? onDoubleTapDetails;
  final bool selectable;
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final BorderRadius? borderRadius;
  final Color? highlightColor;
  final GlobalKey? externalSnapshotKey;
  final Widget child;

  const _MessageGestureRegion({
    required this.onTap,
    required this.onDoubleTap,
    required this.onDoubleTapDetails,
    required this.selectable,
    required this.onSelectionChanged,
    required this.borderRadius,
    required this.highlightColor,
    required this.externalSnapshotKey,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final fallbackSnapshotKey = useMemoized(GlobalKey.new, const []);
    final snapshotKey = externalSnapshotKey ?? fallbackSnapshotKey;
    final sourceHidden = useState(false);
    final regionId = useMemoized(Object.new, const []);
    final selectionKey = useMemoized(
      GlobalKey<SelectionAreaState>.new,
      const [],
    );
    // Selecting text must not take the keyboard away from the composer, so
    // the region never gets focus. Copy/Select all, handle drags, and the
    // magnifier do not need it.
    final selectionFocus = useMemoized(
      () => FocusNode(
        debugLabel: 'MessageSelection',
        canRequestFocus: false,
        skipTraversal: true,
      ),
      const [],
    );
    useEffect(() => selectionFocus.dispose, [selectionFocus]);
    final lastTapUp = useRef<Offset?>(null);
    final latestOnTap = useRef(onTap)..value = onTap;
    final latestOnDoubleTap = useRef(onDoubleTap)..value = onDoubleTap;
    final latestOnDoubleTapDetails = useRef(onDoubleTapDetails)
      ..value = onDoubleTapDetails;
    final latestOnSelectionChanged = useRef(onSelectionChanged)
      ..value = onSelectionChanged;

    useEffect(
      () => () {
        if (_pendingTap?.owner == regionId) cancelPendingMessageTap();
        if (_activeSelectionKey == selectionKey) _activeSelectionKey = null;
      },
      const [],
    );

    // A scroll cancels a pending tap and drops the selection, which also
    // keeps handles from lingering over the app bar once the row scrolls
    // away (the pane's list is not a selection-aware scrollable).
    final scrollObserver = ScrollNotificationObserver.maybeOf(context);
    useEffect(() {
      if (scrollObserver == null) return null;
      void onScroll(ScrollNotification notification) {
        if (notification.depth != 0) return;
        final userScroll =
            notification is ScrollStartNotification ||
            (notification is ScrollUpdateNotification &&
                notification.dragDetails != null);
        if (!userScroll) return;
        cancelPendingMessageTap();
        if (_activeSelectionKey == selectionKey) {
          dismissActiveMessageSelection();
        }
      }

      scrollObserver.addListener(onScroll);
      return () => scrollObserver.removeListener(onScroll);
    }, [scrollObserver, selectionKey]);

    void recognize() {
      final renderObject = snapshotKey.currentContext?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary || !renderObject.hasSize) {
        return;
      }
      final anchorRect =
          renderObject.localToGlobal(Offset.zero) & renderObject.size;

      final detailsCallback = latestOnDoubleTapDetails.value;
      if (detailsCallback == null) {
        latestOnDoubleTap.value?.call(anchorRect);
        return;
      }
      final maxSnapshotPixelRatio = math.min(
        MediaQuery.devicePixelRatioOf(context),
        2.0,
      );

      Future<ui.Image> captureSnapshot() async {
        RenderRepaintBoundary? boundary;
        final renderObject = snapshotKey.currentContext?.findRenderObject();
        if (renderObject is RenderRepaintBoundary && renderObject.hasSize) {
          boundary = renderObject;
        }
        if (boundary == null) {
          throw StateError('Message snapshot is unavailable');
        }
        final snapshotPixelRatio = _messageSnapshotPixelRatio(
          boundary.size,
          maxSnapshotPixelRatio,
        );
        try {
          return await boundary.toImage(pixelRatio: snapshotPixelRatio);
        } catch (_) {
          await WidgetsBinding.instance.endOfFrame;
          final retryBoundary = snapshotKey.currentContext?.findRenderObject();
          if (retryBoundary is! RenderRepaintBoundary ||
              !retryBoundary.hasSize) {
            rethrow;
          }
          try {
            return await retryBoundary.toImage(
              pixelRatio: _messageSnapshotPixelRatio(
                retryBoundary.size,
                maxSnapshotPixelRatio,
              ),
            );
          } catch (_) {
            if (snapshotPixelRatio <= 1) rethrow;
            return retryBoundary.toImage(
              pixelRatio: _messageSnapshotPixelRatio(retryBoundary.size, 1),
            );
          }
        }
      }

      void setSourceHidden(bool hidden) {
        if (!context.mounted) return;
        sourceHidden.value = hidden;
      }

      detailsCallback(
        MessageGestureDetails(
          anchorRect: anchorRect,
          captureSnapshot: captureSnapshot,
          setSourceHidden: setSourceHidden,
        ),
      );
    }

    Future<void> openActions() async {
      cancelPendingMessageTap();
      if (dismissActiveMessageSelection()) {
        // The highlight is painted inside the snapshot boundary; let the
        // cleared frame paint before the preview is captured.
        await WidgetsBinding.instance.endOfFrame;
        if (!context.mounted) return;
      }
      recognize();
    }

    final latestOpenActions = useRef(openActions)..value = openActions;
    final stableOpenActions = useMemoized(
      () =>
          () => unawaited(latestOpenActions.value()),
      const [],
    );

    void handleTap() {
      final position = lastTapUp.value ?? Offset.zero;
      final pending = _pendingTap;
      if (pending != null &&
          pending.owner == regionId &&
          pending.secondDown &&
          (position - pending.position).distance <= kDoubleTapSlop) {
        cancelPendingMessageTap();
        unawaited(openActions());
        return;
      }
      cancelPendingMessageTap();
      // A tap while text is selected only dismisses the selection (a second
      // tap still opens the actions).
      final dismissOnly = dismissActiveMessageSelection();
      final tap = _PendingTap(
        owner: regionId,
        position: position,
        dismissOnly: dismissOnly,
      );
      tap.timer = Timer(kDoubleTapTimeout, () {
        if (!identical(_pendingTap, tap)) return;
        _pendingTap = null;
        if (tap.dismissOnly || !context.mounted) return;
        if (ModalRoute.isCurrentOf(context) == false) return;
        latestOnTap.value?.call();
      });
      _pendingTap = tap;
    }

    void handlePointerDown(PointerDownEvent event) {
      final pending = _pendingTap;
      if (pending == null) return;
      final timer = pending.timer;
      final isSecondTap =
          pending.owner == regionId &&
          !pending.secondDown &&
          timer != null &&
          timer.isActive &&
          (event.position - pending.position).distance <= kDoubleTapSlop;
      if (!isSecondTap) {
        // Another row, a nested control, or the start of a scroll: the first
        // tap must not fire on top of whatever this press does.
        cancelPendingMessageTap();
        return;
      }
      // Stop the clock at the second press so holding it past the timeout
      // cannot let the single tap slip out first.
      timer.cancel();
      pending.timer = null;
      pending.secondDown = true;
      pending.secondPointer = event.pointer;
    }

    void handlePointerEnd(PointerEvent event) {
      final pending = _pendingTap;
      if (pending == null ||
          pending.owner != regionId ||
          !pending.secondDown ||
          pending.secondPointer != event.pointer) {
        return;
      }
      // The arena is swept after this raw event; if the InkWell recognises
      // the tap, handleTap consumes the pending entry before the microtask.
      scheduleMicrotask(() {
        if (identical(_pendingTap, pending)) cancelPendingMessageTap();
      });
    }

    void trackSelection(SelectedContent? content) {
      final hasSelection = content != null && content.plainText.isNotEmpty;
      if (hasSelection) {
        if (_activeSelectionKey != selectionKey) {
          final previous = _activeSelectionKey;
          _activeSelectionKey = selectionKey;
          _clearSelectionOf(previous);
        }
      } else if (_activeSelectionKey == selectionKey) {
        _activeSelectionKey = null;
      }
      latestOnSelectionChanged.value?.call(content);
    }

    Widget core = Listener(
      onPointerDown: handlePointerDown,
      onPointerUp: handlePointerEnd,
      onPointerCancel: handlePointerEnd,
      child: InkWell(
        onTap: handleTap,
        onTapUp: (details) => lastTapUp.value = details.globalPosition,
        excludeFromSemantics: true,
        borderRadius: borderRadius,
        highlightColor: highlightColor,
        child: Opacity(
          opacity: sourceHidden.value ? 0 : 1,
          child: externalSnapshotKey == null
              ? RepaintBoundary(key: snapshotKey, child: child)
              : child,
        ),
      ),
    );
    if (selectable) {
      core = SelectionArea(
        key: selectionKey,
        focusNode: selectionFocus,
        onSelectionChanged: trackSelection,
        child: core,
      );
    }

    return Semantics(
      onTap: onTap,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Message actions'):
            stableOpenActions,
      },
      child: MessageGestureScope(openActions: stableOpenActions, child: core),
    );
  }
}
