part of '../compose_bar.dart';

/// What a hardware key does while a suggestion popover is open. Mirrors
/// desktop's `handleMentionKeyDown` / `handleChannelKeyDown`: the arrows move
/// the highlight (wrapping at either end), Tab and a plain Enter insert the
/// highlighted row, Escape closes the popover.
///
/// Shift+Tab stays a backward focus move and a modified arrow stays text
/// navigation. Enter mid-composition is left to the IME so a Korean or
/// Japanese syllable commits instead of picking a row; Tab still completes
/// during composition, because the composed syllables are the query.
enum SuggestionKeyAction { moveUp, moveDown, select, dismiss }

@visibleForTesting
SuggestionKeyAction? suggestionKeyAction(
  KeyEvent event, {
  required bool composing,
}) {
  final repeat = event is KeyRepeatEvent;
  if (event is! KeyDownEvent && !repeat) return null;
  final keyboard = HardwareKeyboard.instance;
  final modified =
      keyboard.isShiftPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.arrowDown) {
    return modified ? null : SuggestionKeyAction.moveDown;
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    return modified ? null : SuggestionKeyAction.moveUp;
  }
  // Holding a key repeats only the arrows; a held Tab or Enter picks once.
  if (repeat) return null;
  if (key == LogicalKeyboardKey.tab) {
    return modified ? null : SuggestionKeyAction.select;
  }
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return modified || composing ? null : SuggestionKeyAction.select;
  }
  if (key == LogicalKeyboardKey.escape) return SuggestionKeyAction.dismiss;
  return null;
}

/// The highlighted row for [query]: the remembered index while it still
/// belongs to this query and fits the list, otherwise the top row.
int _suggestionHighlightIndex(
  (String?, int) remembered,
  String? query,
  int count,
) {
  if (count == 0 || remembered.$1 != query) return 0;
  return remembered.$2.clamp(0, count - 1);
}

/// Jumps a suggestion list to its top or bottom edge when the keyboard
/// highlight lands there, and back to the top whenever the list changes.
/// Rows in between reveal themselves ([_RevealWhenSelected]); the edges need
/// the controller because a wrapped-to row may not have been built yet.
void _useSuggestionEdgeReveal(
  ScrollController controller,
  int selectedIndex,
  int count,
) {
  useEffect(() {
    if (selectedIndex != 0 && selectedIndex != count - 1) return null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final position = controller.position;
      controller.jumpTo(
        selectedIndex == 0
            ? position.minScrollExtent
            : position.maxScrollExtent,
      );
    });
    return null;
  }, [selectedIndex, count]);
}

/// Keeps the keyboard-highlighted row in view as the arrows move it —
/// scrolling only as far as needed, whichever way the row left the viewport.
/// Only a row that *becomes* highlighted scrolls; a row rebuilt while already
/// highlighted (the list scrolled by hand) stays put.
class _RevealWhenSelected extends HookWidget {
  final bool selected;
  final Widget child;

  const _RevealWhenSelected({required this.selected, required this.child});

  @override
  Widget build(BuildContext context) {
    final isFirstBuild = useRef(true);
    useEffect(() {
      if (isFirstBuild.value) {
        isFirstBuild.value = false;
        return null;
      }
      if (!selected) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
      });
      return null;
    }, [selected]);
    return child;
  }
}

Color _suggestionHighlightColor(BuildContext context) =>
    context.colors.primary.withValues(alpha: 0.12);

class _MentionSuggestions extends HookWidget {
  final List<MentionCandidate> suggestions;
  final Map<String, UserProfile> userCache;
  final String? currentPubkey;
  final bool isDmChannel;

  /// The row Tab/Enter would insert; moved by the arrow keys.
  final int selectedIndex;
  final void Function(MentionCandidate) onSelect;

  const _MentionSuggestions({
    required this.suggestions,
    required this.userCache,
    required this.currentPubkey,
    required this.isDmChannel,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scrollController = useScrollController();
    _useSuggestionEdgeReveal(
      scrollController,
      selectedIndex,
      suggestions.length,
    );
    return Material(
      key: const ValueKey('mention-suggestions-popover'),
      type: MaterialType.card,
      color: appPopoverColor(context),
      surfaceTintColor: Colors.transparent,
      elevation: appPopoverElevation,
      shadowColor: appPopoverShadowColor(context),
      shape: appPopoverShape(context),
      clipBehavior: Clip.hardEdge,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: ListView.separated(
          controller: scrollController,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: Grid.xxs),
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => const SizedBox.shrink(),
          itemBuilder: (context, index) {
            final candidate = suggestions[index];
            final name = candidate.label;
            final avatarUrl =
                candidate.avatarUrl ?? userCache[candidate.pubkey]?.avatarUrl;
            final selected = index == selectedIndex;

            return _RevealWhenSelected(
              selected: selected,
              child: ListTile(
                key: ValueKey('mention-suggestion-$index'),
                dense: true,
                visualDensity: VisualDensity.compact,
                selected: selected,
                selectedTileColor: _suggestionHighlightColor(context),
                selectedColor: context.colors.onSurface,
                leading: AvatarImage(
                  imageUrl: avatarUrl,
                  radius: 18,
                  backgroundColor: context.colors.primaryContainer,
                  fallback: Text(
                    name[0].toUpperCase(),
                    style: context.textTheme.labelMedium?.copyWith(
                      color: context.colors.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  isAgent: candidate.isAgent,
                ),
                title: Text(name, style: context.textTheme.titleSmall),
                subtitle: _MentionSuggestionInfo.build(
                  context,
                  candidate: candidate,
                  currentPubkey: currentPubkey,
                  isDmChannel: isDmChannel,
                  userCache: userCache,
                ),
                onTap: () => _runComposerAction(() => onSelect(candidate)),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The secondary info line under a mention suggestion — mirrors desktop's
/// `MentionAutocomplete` subtitle: bot icon + "agent" (or an "admin" badge
/// for human admins), then "managed by …" / "not in channel".
abstract final class _MentionSuggestionInfo {
  static Widget? build(
    BuildContext context, {
    required MentionCandidate candidate,
    required String? currentPubkey,
    required bool isDmChannel,
    required Map<String, UserProfile> userCache,
  }) {
    if (candidate.teamMembers case final members?) {
      return Row(
        children: [
          Icon(
            LucideIcons.users,
            size: 12,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Grid.half),
          Text(
            'team · ${members.length} agent${members.length == 1 ? '' : 's'}',
            style: context.textTheme.labelSmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final ownerLabel = candidate.isAgent
        ? formatOwnerLabel(candidate.ownerPubkey, currentPubkey, userCache)
        : null;
    final notInChannel = !isDmChannel && !candidate.isMember;
    final isAdmin = !candidate.isAgent && candidate.role == 'admin';

    final String? detail;
    if (ownerLabel != null && notInChannel) {
      detail = 'managed by $ownerLabel \u00b7 not in channel';
    } else if (ownerLabel != null) {
      detail = 'managed by $ownerLabel';
    } else if (notInChannel) {
      detail = 'not in channel';
    } else {
      detail = null;
    }

    if (!candidate.isAgent && !isAdmin && detail == null) return null;

    final style = context.textTheme.labelSmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );

    return Row(
      children: [
        if (candidate.isAgent) ...[
          Icon(
            LucideIcons.bot,
            size: 12,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Grid.half),
          Text('agent', style: style),
        ] else if (isAdmin)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Grid.xxs,
              vertical: 1,
            ),
            decoration: BoxDecoration(
              color: context.colors.secondaryContainer,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(
              'admin',
              style: style?.copyWith(
                color: context.colors.onSecondaryContainer,
              ),
            ),
          ),
        if (detail != null) ...[
          if (candidate.isAgent || isAdmin) const SizedBox(width: Grid.xxs),
          Flexible(
            child: Text(detail, style: style, overflow: TextOverflow.ellipsis),
          ),
        ],
      ],
    );
  }
}

@visibleForTesting
List<Channel> filterChannels(List<Channel> channels, String? query) {
  if (query == null) return const [];
  final q = query.toLowerCase();
  return channels
      .where((c) => c.channelType != 'dm')
      .where((c) {
        if (q.isEmpty) return true;
        return c.name.toLowerCase().contains(q);
      })
      .take(8)
      .toList();
}

class _ChannelSuggestions extends HookWidget {
  final List<Channel> suggestions;

  /// The row Tab/Enter would insert; moved by the arrow keys.
  final int selectedIndex;
  final void Function(Channel) onSelect;

  const _ChannelSuggestions({
    required this.suggestions,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scrollController = useScrollController();
    _useSuggestionEdgeReveal(
      scrollController,
      selectedIndex,
      suggestions.length,
    );
    return Material(
      key: const ValueKey('channel-suggestions-popover'),
      type: MaterialType.card,
      color: appPopoverColor(context),
      surfaceTintColor: Colors.transparent,
      elevation: appPopoverElevation,
      shadowColor: appPopoverShadowColor(context),
      shape: appPopoverShape(context),
      clipBehavior: Clip.hardEdge,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: ListView.separated(
          controller: scrollController,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: Grid.xxs),
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => const SizedBox.shrink(),
          itemBuilder: (context, index) {
            final channel = suggestions[index];
            final selected = index == selectedIndex;
            return _RevealWhenSelected(
              selected: selected,
              child: ListTile(
                key: ValueKey('channel-suggestion-$index'),
                dense: true,
                visualDensity: VisualDensity.compact,
                horizontalTitleGap: 0,
                selected: selected,
                selectedTileColor: _suggestionHighlightColor(context),
                selectedColor: context.colors.onSurface,
                leading: SizedBox.square(
                  dimension: 36,
                  child: Icon(
                    LucideIcons.hash,
                    size: 20,
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                title: Text(channel.name, style: context.textTheme.bodyLarge),
                onTap: () => _runComposerAction(() => onSelect(channel)),
              ),
            );
          },
        ),
      ),
    );
  }
}
