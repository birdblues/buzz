import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../activity/compose_drafts_provider.dart';

/// Selection bridge from a sandboxed app to the composer
/// (`docs/sandboxed-apps.md`, "Selection bridge").
///
/// The app calls `window.__buzzHost.select({ kind, ref, text })` — the one
/// host-owned surface the agent skill's `buzzBridge` runtime looks for. The
/// native hardening script turns that into a single JSON string on the
/// `buzzHost` JavaScript channel; this file validates the string and turns
/// it into a composer draft. Nothing is ever sent on the user's behalf: the
/// host prefills the composer of the message the app was shared in and the
/// user edits and sends.
///
/// The other direction is deliberately narrow (`sandbox_session.dart`): when
/// the message carrying the app is edited to a new blob, the host reads the
/// running app's view state back through one host-owned script, loads the
/// new document into the same WebView, and hands that state to it. No agent
/// text is pushed into the app.

/// Name of the JavaScript channel the sandbox page registers. Inside the
/// document it is `window.buzzHost.postMessage(string)`.
const sandboxBridgeChannelName = 'buzzHost';

/// Caps re-applied here whatever the app promised: one message may carry at
/// most this much text, and no more than one message per interval is read.
const sandboxBridgeMaxTextLength = 2048;

/// A `layout` message carries every moved node as fenced JSON, so it may be
/// longer than a selection line. It is never truncated: a cut JSON is
/// useless, so an app that would exceed this refuses to send instead.
const sandboxBridgeMaxLayoutTextLength = 8192;
const sandboxBridgeMaxRefLength = 200;

/// The raw channel message: the fields above plus JSON escaping, which can
/// double a text made of quotes and newlines. Sized so a full-length layout
/// message always fits.
const sandboxBridgeMaxRawLength = 32 * 1024;
const sandboxBridgeMinInterval = Duration(milliseconds: 500);

/// Where a selection goes: the composer of the message the app was shared
/// in. The host knows this from the message row that opened the app and
/// never takes it from the app's payload.
@immutable
class SandboxBridgeTarget {
  final String channelId;

  /// Event id of the message carrying the app attachment. Its first eight
  /// characters are stamped into the prefilled text so the agent can find
  /// the app the reader was looking at.
  final String messageId;

  /// Set when the message lives in a thread: the thread composer's key.
  final String? threadHeadId;

  /// Root of the thread the message belongs to (the message itself when it
  /// is a top-level one). The wide shell uses it to tell whether the thread
  /// beside an app pane is this message's thread.
  final String? threadRootId;

  /// How many `text/html` attachments the message carries. A session is
  /// keyed to the message only when there is exactly one, so a new version
  /// of the app can swap in place; with several, sessions fall back to the
  /// blob hash and never swap.
  final int htmlAttachmentCount;

  const SandboxBridgeTarget({
    required this.channelId,
    required this.messageId,
    this.threadHeadId,
    this.threadRootId,
    this.htmlAttachmentCount = 1,
  });

  String get draftKey => composeDraftKey(channelId, threadHeadId: threadHeadId);

  SandboxBridgeTarget copyWith({
    String? threadHeadId,
    String? threadRootId,
    int? htmlAttachmentCount,
  }) {
    return SandboxBridgeTarget(
      channelId: channelId,
      messageId: messageId,
      threadHeadId: threadHeadId ?? this.threadHeadId,
      threadRootId: threadRootId ?? this.threadRootId,
      htmlAttachmentCount: htmlAttachmentCount ?? this.htmlAttachmentCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SandboxBridgeTarget &&
      other.channelId == channelId &&
      other.messageId == messageId &&
      other.threadHeadId == threadHeadId &&
      other.threadRootId == threadRootId &&
      other.htmlAttachmentCount == htmlAttachmentCount;

  @override
  int get hashCode => Object.hash(
    channelId,
    messageId,
    threadHeadId,
    threadRootId,
    htmlAttachmentCount,
  );
}

/// What an app may point at. Anything else is dropped. `layout` is not a
/// selection but the app's moved-node positions, sent as fenced JSON in the
/// text for the agent to pin into the graph's data.
enum SandboxSelectKind { node, edge, path, layout }

/// Text cap for one [SandboxSelectKind].
int sandboxBridgeMaxTextFor(SandboxSelectKind kind) => switch (kind) {
  SandboxSelectKind.layout => sandboxBridgeMaxLayoutTextLength,
  _ => sandboxBridgeMaxTextLength,
};

/// One validated selection message.
@immutable
class SandboxSelect {
  final SandboxSelectKind kind;

  /// The app's own element id (a node id, an edge id, `a>b` for a path).
  final String ref;

  /// The human-readable line the app composed, already capped.
  final String text;

  const SandboxSelect({
    required this.kind,
    required this.ref,
    required this.text,
  });
}

/// Parses one channel message. Returns null for anything that is not a JSON
/// object with `kind` in {node, edge, path, layout}, a single-line `ref` of
/// at most [sandboxBridgeMaxRefLength] characters, and a non-empty `text` of
/// at most [sandboxBridgeMaxTextFor] characters for its kind. Control
/// characters other than newline and tab are stripped from the text; the
/// ref may hold none.
SandboxSelect? parseSandboxSelect(String raw) {
  if (raw.isEmpty || raw.length > sandboxBridgeMaxRawLength) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  final kindRaw = decoded['kind'];
  if (kindRaw is! String) return null;
  final kind = SandboxSelectKind.values
      .where((value) => value.name == kindRaw)
      .firstOrNull;
  if (kind == null) return null;

  final refRaw = decoded['ref'];
  if (refRaw is! String || refRaw.length > sandboxBridgeMaxRefLength) {
    return null;
  }
  final ref = refRaw.trim();
  if (ref.isEmpty || _controlChars.hasMatch(ref)) return null;

  final textRaw = decoded['text'];
  if (textRaw is! String || textRaw.length > sandboxBridgeMaxTextFor(kind)) {
    return null;
  }
  final text = textRaw.replaceAll(_controlCharsExceptBreaks, '').trim();
  if (text.isEmpty) return null;

  return SandboxSelect(kind: kind, ref: ref, text: text);
}

final _controlChars = RegExp(r'[\x00-\x1f\x7f]');
final _controlCharsExceptBreaks = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');

/// The composer line for [select]: the app's text with the first eight
/// characters of the app message's id stamped into its leading `[…]` tag
/// (`[인과그래프] 간선 …` becomes `[인과그래프 #1a2b3c4d] 간선 …`), or
/// prefixed with `[앱 #…]` when the text carries no tag. The agent resolves
/// the app from that tag; the app never supplies it.
String sandboxBridgePrefillText({
  required SandboxSelect select,
  required String messageId,
}) {
  final tag = messageId.length > 8 ? messageId.substring(0, 8) : messageId;
  final text = select.text;
  final leading = _leadingTag.firstMatch(text);
  if (leading != null) {
    return '[${leading.group(1)} #$tag]${text.substring(leading.end)}';
  }
  return '[앱 #$tag] $text';
}

final _leadingTag = RegExp(r'^\[([^\[\]\n#]{1,40})\](?=\s)');

/// Drops messages that arrive faster than [sandboxBridgeMinInterval] apart —
/// the app promises the same cap; this one holds when it does not.
class SandboxBridgeRateLimiter {
  DateTime? _last;

  bool allow(DateTime now) {
    final last = _last;
    if (last != null && now.difference(last) < sandboxBridgeMinInterval) {
      return false;
    }
    _last = now;
    return true;
  }
}

/// A composer prefill requested by a sandboxed app: the full draft text for
/// the composer identified by [key]. [seq] makes every request a new state
/// even when the text repeats.
@immutable
class ComposerPrefill {
  final String key;
  final String text;
  final int seq;

  const ComposerPrefill({
    required this.key,
    required this.text,
    required this.seq,
  });

  @override
  bool operator ==(Object other) =>
      other is ComposerPrefill &&
      other.key == key &&
      other.text == text &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(key, text, seq);
}

/// Hands a bridge selection to the right composer.
///
/// The text is appended to that composer's persisted draft first, so a
/// composer that is not mounted yet (a thread the reader has not opened)
/// picks it up when it mounts; a mounted composer listens to this provider
/// and shows the merged draft at once.
class ComposerPrefillNotifier extends Notifier<ComposerPrefill?> {
  int _seq = 0;

  @override
  ComposerPrefill? build() => null;

  void request({
    required String channelId,
    String? threadHeadId,
    required String text,
  }) {
    final key = composeDraftKey(channelId, threadHeadId: threadHeadId);
    final drafts = ref.read(composeDraftsProvider.notifier);
    final existing = drafts.textFor(key);
    final merged = existing == null || existing.trim().isEmpty
        ? text
        : '$existing\n$text';
    drafts.save(
      key: key,
      channelId: channelId,
      threadHeadId: threadHeadId,
      text: merged,
    );
    state = ComposerPrefill(key: key, text: merged, seq: ++_seq);
  }
}

final composerPrefillProvider =
    NotifierProvider<ComposerPrefillNotifier, ComposerPrefill?>(
      ComposerPrefillNotifier.new,
    );
