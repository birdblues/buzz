import 'package:flutter/material.dart';

/// Shows [snackBar] on [messenger] only while it can still present one.
///
/// A messenger captured before an await can be torn down before the result
/// arrives: the wide shell gives each pane its own [ScaffoldMessenger], so
/// closing a pane disposes the messenger a send in flight is holding.
/// `showSnackBar` asserts it still has a Scaffold to present to, so an
/// unguarded late report would crash instead of being dropped.
void showSnackBarIfPresentable(
  ScaffoldMessengerState? messenger,
  SnackBar snackBar,
) {
  if (messenger == null || !messenger.mounted) return;
  messenger.showSnackBar(snackBar);
}
