import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every production route to a channel, thread, or forum post must go through
/// `channel_navigation.dart`, which decides between pushing a full-screen
/// route and selecting a wide-shell pane. A direct push elsewhere would work
/// on phones and silently break the iPad layout.
void main() {
  test('pages are only pushed through the channel navigation facade', () {
    final allowed = {
      'lib/features/channels/channel_navigation.dart',
      // The shell mounts pages as pane roots rather than pushing them.
      'lib/features/home/wide_home_shell/main_pane.dart',
      'lib/features/home/wide_home_shell/aux_pane.dart',
      // The phone home exists only in the compact layout, so it may push
      // Activity and Search itself.
      'lib/features/home/home_page.dart',
    };
    final pattern = RegExp(
      r'=>\s*(ChannelDetailPage|ThreadDetailPage|ForumThreadPage'
      r'|ActivityPage|SearchPage)\(',
    );
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (allowed.contains(path)) continue;
      final source = entity.readAsStringSync();
      for (final match in pattern.allMatches(source)) {
        final line = source.substring(0, match.start).split('\n').length;
        offenders.add('$path:$line');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Route to these pages via openChannelDetail / openThreadDetail / '
          'openForumThread in channel_navigation.dart instead.',
    );
  });
}
