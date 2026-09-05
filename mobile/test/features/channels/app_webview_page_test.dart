import 'package:buzz/features/channels/app_webview_page.dart';
import 'package:buzz/features/channels/message_content/app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
final _initial = Uri.parse('http://192.168.1.99:3001/app/$_sha.html');

void main() {
  group('isAllowedAppNavigation', () {
    test('allows only the app document itself', () {
      expect(
        isAllowedAppNavigation(
          initial: _initial,
          requested: _initial.toString(),
        ),
        isTrue,
      );
    });

    test('refuses every other navigation', () {
      for (final requested in [
        'https://example.com/?leak=1',
        'http://192.168.1.99:3001/app/$_sha.html?x=1',
        'http://192.168.1.99:3001/app/$_sha.html#frag',
        'http://192.168.1.99:3000/media/$_sha.html',
        'http://192.168.1.99:3001/app/${'f' * 64}.html',
        'about:blank',
        'javascript:void(0)',
        'data:text/html,hi',
        'blob:null/abc',
        '',
      ]) {
        expect(
          isAllowedAppNavigation(initial: _initial, requested: requested),
          isFalse,
          reason: requested,
        );
      }
    });
  });

  group('AppCard helpers', () {
    test('pickThemedPreview matches the theme and falls back', () {
      expect(
        pickThemedPreview(brightness: Brightness.light, light: 'l', dark: 'd'),
        'l',
      );
      expect(
        pickThemedPreview(brightness: Brightness.dark, light: 'l', dark: 'd'),
        'd',
      );
      expect(
        pickThemedPreview(brightness: Brightness.dark, light: 'l', dark: null),
        'l',
      );
      expect(
        pickThemedPreview(brightness: Brightness.light, light: null, dark: 'd'),
        'd',
      );
      expect(
        pickThemedPreview(
          brightness: Brightness.light,
          light: null,
          dark: null,
        ),
        isNull,
      );
    });

    test('formatAppFileSize', () {
      expect(formatAppFileSize(512), '512 B');
      expect(formatAppFileSize(20480), '20 KB');
      expect(formatAppFileSize(1536), '1.5 KB');
      expect(formatAppFileSize(8 * 1024 * 1024), '8.0 MB');
      expect(formatAppFileSize(-1), '');
    });
  });
}
