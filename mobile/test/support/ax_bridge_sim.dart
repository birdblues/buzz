// A Dart re-implementation of the checks the desktop engines run on every
// semantics update (`shell/platform/common/accessibility_bridge.cc` +
// `third_party/accessibility/ax/ax_tree.cc`, Flutter 3.41.7).
//
// The macOS and Windows embedders feed each framework update into a
// `ui::AXTree`. That tree accepts an update only when every node in it
// already exists or is created by a parent earlier in the same update, and
// it refuses to move a node between parents in one update. When a check
// fails the whole update is dropped, the tree diverges from the framework's,
// and the engine logs `Failed to update ui::AXTree, error: …` — and keeps
// logging that same string on every later commit, because `AXTree::error_`
// is never cleared.
//
// `AxBridgeSimBinding` installs a recording `SemanticsUpdateBuilder` so a
// widget test can replay the framework's updates through the same checks
// and fail on the first update the real engine would have dropped.
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// One failed update, worded like the engine's log line.
class AxBridgeFailure {
  final int commit;
  final String error;
  final List<AxNodeUpdate> update;

  AxBridgeFailure(this.commit, this.error, this.update);

  @override
  String toString() =>
      'commit #$commit: Failed to update ui::AXTree, error: $error\n'
      '  update: ${update.map((n) => '${n.id}→${n.children}').join(', ')}';
}

/// The two fields the bridge uses to shape the tree.
class AxNodeUpdate {
  final int id;
  final List<int> children;
  final String label;

  const AxNodeUpdate(this.id, this.children, this.label);
}

class _AxNode {
  final int id;
  int? parent;
  List<int> children;

  _AxNode(this.id, this.parent, this.children);
}

/// Mirrors `AccessibilityBridge` (ordering + reparent split) and the
/// structural part of `AXTree::Unserialize`.
class AxBridgeSim {
  final Map<int, _AxNode> _tree = {};
  int? _rootId;
  int _commits = 0;
  final List<AxBridgeFailure> failures = [];

  /// Distinct error strings seen so far, in order of first appearance.
  List<String> get transitions => failures.map((f) => f.error).toList();

  bool contains(int id) => _tree.containsKey(id);
  int? parentOf(int id) => _tree[id]?.parent;
  int get size => _tree.length;

  void reset() {
    _tree.clear();
    _rootId = null;
    _commits = 0;
    failures.clear();
  }

  /// `AccessibilityBridge::CommitUpdates`.
  void commit(List<AxNodeUpdate> nodes) {
    _commits += 1;
    final pending = LinkedHashMap<int, AxNodeUpdate>.fromEntries(
      nodes.map((n) => MapEntry(n.id, n)),
    );

    // Phase 1: remove nodes that move to a new parent from their old one.
    final removals = <int, List<int>>{};
    for (final update in pending.values) {
      for (final childId in update.children) {
        final child = _tree[childId];
        if (child == null || child.parent == null) continue;
        if (child.parent == update.id) continue;
        final oldParent = child.parent!;
        removals
            .putIfAbsent(oldParent, () => List.of(_tree[oldParent]!.children))
            .remove(childId);
      }
    }
    if (removals.isNotEmpty) {
      final removal = [
        for (final e in removals.entries) AxNodeUpdate(e.key, e.value, ''),
      ];
      final error = _unserialize(removal, null);
      if (error != null) {
        failures.add(AxBridgeFailure(_commits, error, removal));
        return; // the engine returns here without applying phase 2
      }
    }

    // Phase 2: order parent-before-child the way the bridge does.
    final results = <List<AxNodeUpdate>>[];
    while (pending.isNotEmpty) {
      final target = pending.values.first;
      pending.remove(target.id);
      final list = <AxNodeUpdate>[];
      _subTree(target, pending, list);
      results.add(list);
    }
    final ordered = <AxNodeUpdate>[
      for (var i = results.length; i > 0; i--) ...results[i - 1],
    ];
    int? newRoot;
    if (ordered.isNotEmpty && _rootId == null) {
      newRoot = results.last.first.id;
    }
    final error = _unserialize(ordered, newRoot);
    if (error != null) {
      failures.add(AxBridgeFailure(_commits, error, ordered));
    }
  }

  void _subTree(
    AxNodeUpdate target,
    Map<int, AxNodeUpdate> pending,
    List<AxNodeUpdate> out,
  ) {
    out.add(target);
    for (final child in target.children) {
      final next = pending.remove(child);
      if (next != null) _subTree(next, pending, out);
    }
  }

  /// `AXTree::ComputePendingChanges` + apply. Returns the error, or null.
  String? _unserialize(List<AxNodeUpdate> nodes, int? newRootId) {
    final destroyed = <int>{};
    final pendingCreate = <int>{};
    final provided = <int>{};
    final rootWillBeCreated =
        newRootId != null && !_tree.containsKey(newRootId);

    bool existsPending(int id) =>
        (_tree.containsKey(id) && !destroyed.contains(id)) ||
        pendingCreate.contains(id);

    void markSubtreeDestroyed(int id) {
      final node = _tree[id];
      if (node == null || !destroyed.add(id)) return;
      for (final c in node.children) {
        markSubtreeDestroyed(c);
      }
    }

    for (final data in nodes) {
      final isNewRoot = rootWillBeCreated && data.id == newRootId;
      if (!existsPending(data.id)) {
        if (!isNewRoot) {
          return '${data.id} will not be in the tree and is not the new root';
        }
        pendingCreate.add(data.id);
      }
      provided.add(data.id);
      final old = _tree[data.id];
      final oldChildren = old != null && !destroyed.contains(data.id)
          ? old.children
          : const <int>[];
      for (final c in oldChildren) {
        if (!data.children.contains(c)) markSubtreeDestroyed(c);
      }
      final seen = <int>{};
      for (final c in data.children) {
        if (!seen.add(c)) {
          return 'Node ${data.id} has duplicate child id $c';
        }
        if (_tree.containsKey(c) && !destroyed.contains(c)) {
          if (_tree[c]!.parent != data.id) {
            return 'Node $c is not marked for destruction, would be '
                'reparented to ${data.id}';
          }
          continue;
        }
        if (pendingCreate.contains(c)) {
          return 'Node $c is already pending for creation, cannot be a new '
              'child';
        }
        pendingCreate.add(c);
      }
    }
    final left = pendingCreate.where((id) => !provided.contains(id)).toList();
    if (left.isNotEmpty) {
      return 'Nodes left pending by the update: ${left.join(' ')}';
    }

    // Apply.
    for (final id in destroyed) {
      if (!provided.contains(id)) _tree.remove(id);
    }
    for (final data in nodes) {
      _tree[data.id] = _AxNode(
        data.id,
        _tree[data.id]?.parent,
        List.of(data.children),
      );
    }
    for (final data in nodes) {
      for (final c in data.children) {
        _tree[c]?.parent = data.id;
      }
    }
    if (newRootId != null) {
      _rootId = newRootId;
      _tree[newRootId]?.parent = null;
    }
    return null;
  }
}

/// Test binding that replays every semantics update through [AxBridgeSim].
///
/// Call [AxBridgeSimBinding.ensureInitialized] at the top of `main` (before
/// any `testWidgets`), keep a `SemanticsHandle` for the test, and read
/// [AxBridgeSimBinding.sim] after pumping.
class AxBridgeSimBinding extends AutomatedTestWidgetsFlutterBinding {
  final AxBridgeSim sim = AxBridgeSim();

  /// Labels of the nodes seen in the last update, keyed by id — lets a test
  /// say which widget a failing id belongs to.
  final Map<int, String> labels = {};

  static AxBridgeSimBinding ensureInitialized() {
    if (_instance == null) {
      AxBridgeSimBinding();
    }
    return _instance!;
  }

  static AxBridgeSimBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() {
    return _RecordingBuilder(ui.SemanticsUpdateBuilder(), this);
  }
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  final ui.SemanticsUpdateBuilder _inner;
  final AxBridgeSimBinding _binding;
  final List<AxNodeUpdate> _nodes = [];

  _RecordingBuilder(this._inner, this._binding);

  @override
  void updateNode({
    required int id,
    required ui.SemanticsFlags flags,
    required int actions,
    required int maxValueLength,
    required int currentValueLength,
    required int textSelectionBase,
    required int textSelectionExtent,
    required int platformViewId,
    required int scrollChildren,
    required int scrollIndex,
    required int traversalParent,
    required double scrollPosition,
    required double scrollExtentMax,
    required double scrollExtentMin,
    required ui.Rect rect,
    required String identifier,
    required String label,
    required List<ui.StringAttribute> labelAttributes,
    required String value,
    required List<ui.StringAttribute> valueAttributes,
    required String increasedValue,
    required List<ui.StringAttribute> increasedValueAttributes,
    required String decreasedValue,
    required List<ui.StringAttribute> decreasedValueAttributes,
    required String hint,
    required List<ui.StringAttribute> hintAttributes,
    required String tooltip,
    required ui.TextDirection? textDirection,
    required Float64List transform,
    required Float64List hitTestTransform,
    required Int32List childrenInTraversalOrder,
    required Int32List childrenInHitTestOrder,
    required Int32List additionalActions,
    int headingLevel = 0,
    String linkUrl = '',
    ui.SemanticsRole role = ui.SemanticsRole.none,
    required List<String>? controlsNodes,
    ui.SemanticsValidationResult validationResult =
        ui.SemanticsValidationResult.none,
    ui.SemanticsHitTestBehavior hitTestBehavior =
        ui.SemanticsHitTestBehavior.defer,
    required ui.SemanticsInputType inputType,
    required ui.Locale? locale,
    required String minValue,
    required String maxValue,
  }) {
    final text = [
      if (label.isNotEmpty) label,
      if (tooltip.isNotEmpty) 'tooltip:$tooltip',
      if (value.isNotEmpty) 'value:$value',
      if (platformViewId != -1) 'platformView:$platformViewId',
      if (traversalParent != -1) 'traversalParent:$traversalParent',
      if (identifier.isNotEmpty) 'id:$identifier',
      'hit:$childrenInHitTestOrder',
      if (scrollChildren > 0) 'scrollChildren:$scrollChildren',
    ].join(' | ');
    _nodes.add(AxNodeUpdate(id, List.of(childrenInTraversalOrder), text));
    _binding.labels[id] = text;
    _inner.updateNode(
      id: id,
      flags: flags,
      actions: actions,
      maxValueLength: maxValueLength,
      currentValueLength: currentValueLength,
      textSelectionBase: textSelectionBase,
      textSelectionExtent: textSelectionExtent,
      platformViewId: platformViewId,
      scrollChildren: scrollChildren,
      scrollIndex: scrollIndex,
      traversalParent: traversalParent,
      scrollPosition: scrollPosition,
      scrollExtentMax: scrollExtentMax,
      scrollExtentMin: scrollExtentMin,
      rect: rect,
      identifier: identifier,
      label: label,
      labelAttributes: labelAttributes,
      value: value,
      valueAttributes: valueAttributes,
      increasedValue: increasedValue,
      increasedValueAttributes: increasedValueAttributes,
      decreasedValue: decreasedValue,
      decreasedValueAttributes: decreasedValueAttributes,
      hint: hint,
      hintAttributes: hintAttributes,
      tooltip: tooltip,
      textDirection: textDirection,
      transform: transform,
      hitTestTransform: hitTestTransform,
      childrenInTraversalOrder: childrenInTraversalOrder,
      childrenInHitTestOrder: childrenInHitTestOrder,
      additionalActions: additionalActions,
      headingLevel: headingLevel,
      linkUrl: linkUrl,
      role: role,
      controlsNodes: controlsNodes,
      validationResult: validationResult,
      hitTestBehavior: hitTestBehavior,
      inputType: inputType,
      locale: locale,
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) {
    _inner.updateCustomAction(
      id: id,
      label: label,
      hint: hint,
      overrideId: overrideId,
    );
  }

  static const bool trace = bool.fromEnvironment('AXTREE_TRACE');

  @override
  ui.SemanticsUpdate build() {
    if (trace) {
      // ignore: avoid_print
      print(
        'AXTREE-COMMIT ${_binding.sim.failures.length} '
        '${_nodes.map((n) => "${n.id}→${n.children} {${n.label.replaceAll("\n", " ")}}").join("  ")}',
      );
    }
    _binding.sim.commit(List.of(_nodes));
    _nodes.clear();
    return _inner.build();
  }
}
