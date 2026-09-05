import '../channels/message_media.dart';

/// Characters of prose a forum post card shows before clipping.
const forumPreviewMaxChars = 200;

final _attachmentLine = RegExp(r'^\s*!?\[[^\]\n]*\]\(([^)\s]+)\)\s*$');

/// The body a forum post card renders: the prose clipped to [maxChars], then
/// every trailing attachment line intact.
///
/// Attachments are written as their own trailing markdown lines
/// (`[file.html](url)`, `![image](url)`) whose URL has an `imeta` tag. A
/// plain character cut lands inside those lines for any long post, leaving
/// broken markdown source in the card instead of the attachment pill or
/// image. Clipping only the prose keeps the attachments renderable.
String forumPostPreview(
  String content,
  List<List<String>> tags, {
  int maxChars = forumPreviewMaxChars,
}) {
  final imetaByUrl = parseImetaTags(tags);
  final lines = content.split('\n');
  var end = lines.length;
  final trailing = <String>[];
  while (end > 0) {
    final line = lines[end - 1];
    if (line.trim().isEmpty) {
      end -= 1;
      continue;
    }
    final match = _attachmentLine.firstMatch(line);
    if (match != null && imetaByUrl.containsKey(match[1])) {
      trailing.insert(0, line.trim());
      end -= 1;
      continue;
    }
    break;
  }
  final prose = lines.sublist(0, end).join('\n').trimRight();
  final clipped = prose.length > maxChars
      ? '${prose.substring(0, maxChars)}...'
      : prose;
  if (trailing.isEmpty) return clipped;
  final attachments = trailing.join('\n');
  return clipped.isEmpty ? attachments : '$clipped\n\n$attachments';
}
