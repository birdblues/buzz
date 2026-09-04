import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/theme/theme_provider.dart';

const _wideSidebarCollapsedKey = 'buzz.wide-sidebar-collapsed.v1';

/// Whether the wide shell's sidebar is hidden. Persisted across launches and
/// shared by every community.
class WideSidebarCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(savedPrefsProvider).getBool(_wideSidebarCollapsedKey) ?? false;

  /// Flips the collapsed state.
  void toggle() => set(!state);

  /// Sets the collapsed state and persists it.
  void set(bool collapsed) {
    state = collapsed;
    ref.read(savedPrefsProvider).setBool(_wideSidebarCollapsedKey, collapsed);
  }
}

/// Whether the wide shell's sidebar is collapsed.
final wideSidebarCollapsedProvider =
    NotifierProvider<WideSidebarCollapsedNotifier, bool>(
      WideSidebarCollapsedNotifier.new,
    );
