import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/theme/theme.dart';
import '../activity/activity_page.dart';
import '../channels/channels_page.dart';
import '../search/search_page.dart';
import 'home_nav_rows.dart';

/// The phone's home: the wide shell's sidebar at full width. The channel list
/// under its community header, the Activity and Search rows pinned beneath,
/// and the profile card as the footer. Activity and Search push as pages;
/// there is no tab bar and no floating action, like the desktop sidebar.
class HomePage extends HookConsumerWidget {
  /// Creates the phone home.
  const HomePage({
    required this.settingsPageBuilder,
    required this.hasUnreadInbox,
    super.key,
  });

  /// Builds the Settings page when the user opens it.
  final WidgetBuilder settingsPageBuilder;

  /// Whether the Activity inbox has unread items.
  final bool hasUnreadInbox;

  static const double _settingsBackgroundScale = 0.97;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsTransitionProgress = useValueNotifier(0.0);
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final topSectionGradient = context.appColors.topSectionGradient;

    void reportSettingsProgress(double progress) {
      if (settingsTransitionProgress.value != progress) {
        settingsTransitionProgress.value = progress;
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            key: const ValueKey('home-settings-transition-backdrop'),
            decoration: BoxDecoration(
              color: topSectionGradient == null ? context.colors.surface : null,
              gradient: topSectionGradient,
            ),
          ),
        ),
        ValueListenableBuilder<double>(
          key: const ValueKey('home-settings-transition-progress'),
          // Keep one stable listenable for Home. Swapping in the route's
          // animation can briefly rebuild with its completed value before the
          // new controller starts, which makes the background scale twice.
          valueListenable: settingsTransitionProgress,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // The footer stays put while the keyboard is up; pushed pages
            // manage their own insets.
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                Expanded(
                  // The footer below takes the bottom safe area, so the list
                  // ends at the divider.
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: ChannelsPage(
                      settingsPageBuilder: settingsPageBuilder,
                      onSettingsTransitionProgress: reportSettingsProgress,
                      pinnedHeader: HomeNavRows(
                        hasUnreadInbox: hasUnreadInbox,
                        onActivity: () => _openActivity(context),
                        onSearch: () => _openSearch(context),
                      ),
                      pinnedHeaderHeight: HomeNavRows.height,
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: context.colors.outlineVariant.withValues(alpha: 0.5),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    Grid.xxs,
                    Grid.xxs,
                    Grid.xxs,
                    Grid.xxs + bottomInset,
                  ),
                  child: SidebarProfileCard(
                    settingsPageBuilder: settingsPageBuilder,
                    onSettingsTransitionProgress: reportSettingsProgress,
                  ),
                ),
              ],
            ),
          ),
          builder: (context, progress, child) {
            final curvedProgress = reducedMotion
                ? 0.0
                : Curves.easeOutCubic.transform(progress);
            return Opacity(
              key: const ValueKey('home-settings-transition-opacity'),
              // Settings supplies the crossfade. Keeping Home opaque beneath
              // it prevents the bare backdrop showing through two partially
              // transparent layers.
              opacity: 1,
              child: Transform.scale(
                key: const ValueKey('home-settings-transition-scale'),
                scale: lerpDouble(1, _settingsBackgroundScale, curvedProgress),
                alignment: Alignment.center,
                child: child,
              ),
            );
          },
        ),
      ],
    );
  }
}

// The phone only ever exists in the compact layout, so these push; the wide
// shell selects a pane surface from the same rows instead.
Future<void> _openActivity(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const ActivityPage()));

Future<void> _openSearch(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => const SearchPage(autofocus: true)),
);
