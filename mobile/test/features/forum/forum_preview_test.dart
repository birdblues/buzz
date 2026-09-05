import 'package:buzz/features/forum/forum_preview.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _appUrl = 'https://relay.example.com/media/$_sha.html';
const _imageUrl = 'https://relay.example.com/media/photo.png';
const _tags = [
  ['h', 'forum-channel'],
  ['imeta', 'url $_appUrl', 'm text/html', 'x $_sha', 'filename app.html'],
  ['imeta', 'url $_imageUrl', 'm image/png'],
];

void main() {
  test('short prose is returned unchanged', () {
    expect(forumPostPreview('Hello forum', _tags), 'Hello forum');
  });

  test('long prose is clipped with an ellipsis', () {
    final long = 'a' * 250;
    expect(forumPostPreview(long, _tags), '${'a' * 200}...');
  });

  test('a trailing attachment line survives the clip', () {
    final long = 'a' * 250;
    expect(
      forumPostPreview('$long\n[app.html]($_appUrl)', _tags),
      '${'a' * 200}...\n\n[app.html]($_appUrl)',
    );
  });

  test('several trailing attachments and blank lines are kept in order', () {
    expect(
      forumPostPreview(
        'Look\n\n![photo]($_imageUrl)\n\n[app.html]($_appUrl)\n',
        _tags,
      ),
      'Look\n\n![photo]($_imageUrl)\n[app.html]($_appUrl)',
    );
  });

  test('a link without an imeta tag is ordinary prose', () {
    final long = 'a' * 250;
    final content = '$long\n[docs](https://example.com/docs)';
    expect(forumPostPreview(content, _tags), '${'a' * 200}...');
  });

  test('an attachment link in the middle of the prose is not lifted', () {
    final content = '[app.html]($_appUrl)\n${'b' * 250}';
    expect(forumPostPreview(content, _tags), '${content.substring(0, 200)}...');
  });

  test('a post that is only an attachment keeps it', () {
    expect(
      forumPostPreview('[app.html]($_appUrl)', _tags),
      '[app.html]($_appUrl)',
    );
  });

  test('without tags nothing is treated as an attachment', () {
    final long = 'a' * 250;
    expect(
      forumPostPreview('$long\n[app.html]($_appUrl)', const []),
      '${'a' * 200}...',
    );
  });
}
