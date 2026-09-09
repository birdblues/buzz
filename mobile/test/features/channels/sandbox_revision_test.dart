import 'package:buzz/features/channels/sandbox_revision.dart';
import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha1 =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _sha2 =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _target = 'msg-1';

List<String> _html(String sha) => [
  'imeta',
  'url https://relay.example/media/$sha.html',
  'm text/html',
  'x $sha',
  'size 10',
  'filename app.html',
];

NostrEvent _event({
  required String id,
  required int kind,
  required int createdAt,
  List<List<String>> tags = const [],
}) => NostrEvent(
  id: id,
  pubkey: 'bot',
  createdAt: createdAt,
  kind: kind,
  tags: tags,
  content: '',
  sig: '',
);

NostrEvent _edit(
  String id,
  int at, {
  List<List<String>> extra = const [],
  String target = _target,
}) => _event(
  id: id,
  kind: EventKind.streamMessageEdit,
  createdAt: at,
  tags: [
    ['h', 'chan'],
    ['e', target],
    ...extra,
  ],
);

void main() {
  group('latestEditFor', () {
    test('picks the newest edit of the target, strictly newer wins', () {
      final first = _edit('e1', 100);
      final tieFirst = _edit('e2', 200);
      final tieSecond = _edit('e3', 200);
      final other = _edit('e4', 300, target: 'msg-2');
      expect(
        latestEditFor([first, tieFirst, tieSecond, other], _target)?.id,
        'e2',
        reason: 'a tie keeps the one seen first, like formatTimeline',
      );
      expect(latestEditFor([tieSecond, tieFirst], _target)?.id, 'e3');
      expect(latestEditFor([other], _target), isNull);
    });

    test('skips a deleted edit and a deleted target', () {
      final e1 = _edit('e1', 100);
      final e2 = _edit('e2', 200);
      final delE2 = _event(
        id: 'd1',
        kind: EventKind.nip29DeleteEvent,
        createdAt: 250,
        tags: [
          ['e', 'e2'],
        ],
      );
      expect(latestEditFor([e1, e2, delE2], _target)?.id, 'e1');
      final delTarget = _event(
        id: 'd2',
        kind: EventKind.deletion,
        createdAt: 300,
        tags: [
          ['e', _target],
        ],
      );
      expect(latestEditFor([e1, e2, delTarget], _target), isNull);
    });
  });

  group('appRevisionFrom', () {
    test('is the standing edit\'s single HTML attachment', () {
      final v1 = _edit('e1', 100, extra: [_html(_sha1)]);
      final v2 = _edit('e2', 200, extra: [_html(_sha2)]);
      final revision = appRevisionFrom([v1, v2], _target);
      expect(revision, isNotNull);
      expect(revision!.sha256, _sha2);
      expect(revision.filename, 'app.html');
      expect(revision.editId, 'e2');
      expect(revision.createdAt, 200);
    });

    test('is null when the message was never edited', () {
      expect(appRevisionFrom(const [], _target), isNull);
    });

    test('does not climb back past a winner without an app', () {
      final v1 = _edit('e1', 100, extra: [_html(_sha1)]);
      final textOnly = _edit('e2', 200);
      expect(appRevisionFrom([v1, textOnly], _target), isNull);
    });

    test('is null when the winner carries several apps', () {
      final two = _edit('e1', 100, extra: [_html(_sha1), _html(_sha2)]);
      expect(appRevisionFrom([two], _target), isNull);
    });

    test('has value equality', () {
      final v = _edit('e1', 100, extra: [_html(_sha1)]);
      expect(appRevisionFrom([v], _target), appRevisionFrom([v], _target));
    });
  });
}
