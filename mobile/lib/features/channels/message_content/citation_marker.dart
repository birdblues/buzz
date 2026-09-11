part of '../message_content.dart';

/// A `[1]`-style citation marker, drawn the way gpt_markdown draws it.
///
/// Claimed only so that it is claimed *first*. `ATagMd`'s pattern ends at the
/// last `]` before a `(`, so `[1] [text](url)` matches whole — but its parser
/// then takes the *first* balanced `]`, finds `[1]`, sees no `(` after it,
/// calls the link malformed and prints the whole run as source text. An agent
/// citing its sources writes exactly that shape, and every link in the list
/// came out as raw markdown. Matching the marker on its own splits the run, so
/// the link that follows reaches `ATagMd` clean.
///
/// The marker itself is handed straight back to the package's own `SourceTag`,
/// so it keeps the superscript it has always had.
class _CitationMarkerMd extends InlineMd {
  static final RegExp _pattern = RegExp(r'\[\d{1,4}\]');
  static final SourceTag _sourceTag = SourceTag();

  @override
  RegExp get exp => _pattern;

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) => _sourceTag.span(context, text, config);
}
