import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'community.dart';

class CommunityStorage {
  static const _keyCommunities = 'buzz_communities';
  static const _keyActiveId = 'buzz_active_community_id';

  // Legacy keys for migration.
  static const _legacyCommunities = 'buzz_workspaces';
  static const _legacyActiveId = 'buzz_active_workspace_id';
  static const _legacyRelayUrl = 'buzz_relay_url';
  static const _legacyToken = 'buzz_token';
  static const _legacyPubkey = 'buzz_pubkey';
  static const _legacyNsec = 'buzz_nsec';

  /// A keychain read that fails is tried again, three times a beat apart.
  /// Right after a relaunch the macOS data-protection keychain can answer
  /// `errSecInteractionNotAllowed` (-25308) for a moment — seen on every
  /// first launch of a fresh build — and the same read succeeds a second
  /// later. Only the platform's own error is retried; after the last attempt
  /// it propagates, because a read that failed must never look like a key
  /// that is absent — "absent" is what signs the user out.
  static const readAttempts = 3;
  static const readRetryDelay = Duration(milliseconds: 250);

  final FlutterSecureStorage _secure;

  CommunityStorage({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();

  Future<String?> _read(String key) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _secure.read(key: key);
      } on PlatformException catch (error, stackTrace) {
        developer.log(
          'Keychain read of $key failed (attempt $attempt/$readAttempts)',
          name: 'buzz.community',
          error: error,
          stackTrace: stackTrace,
        );
        if (attempt >= readAttempts) rethrow;
        await Future<void>.delayed(readRetryDelay * attempt);
      }
    }
  }

  /// Load all communities. On first call, migrates legacy single-community
  /// credentials if present.
  Future<List<Community>> loadAll() async {
    final raw = await _read(_keyCommunities);
    if (raw != null) return _decodeList(raw);

    final legacyCommunities = await _read(_legacyCommunities);
    if (legacyCommunities != null) {
      final communities = _decodeList(legacyCommunities);
      await _saveList(communities);
      final legacyActiveId = await _read(_legacyActiveId);
      if (legacyActiveId != null) await saveActiveId(legacyActiveId);
      await _secure.delete(key: _legacyCommunities);
      await _secure.delete(key: _legacyActiveId);
      return communities;
    }

    // Migration: check for legacy single-community keys.
    final legacyUrl = await _read(_legacyRelayUrl);
    final legacyToken = await _read(_legacyToken);
    if (legacyUrl != null && legacyToken != null) {
      final legacyPubkey = await _read(_legacyPubkey);
      final legacyNsec = await _read(_legacyNsec);

      final name = Community.nameFromUrl(legacyUrl);
      final community = Community.create(
        name: name,
        relayUrl: legacyUrl,
        pubkey: legacyPubkey,
        nsec: legacyNsec,
        sensitiveActionPolicy: SensitiveActionPolicy.disabledByUser,
      );

      await _saveList([community]);
      await saveActiveId(community.id);

      // Delete legacy keys.
      await _secure.delete(key: _legacyRelayUrl);
      await _secure.delete(key: _legacyToken);
      await _secure.delete(key: _legacyPubkey);
      await _secure.delete(key: _legacyNsec);

      return [community];
    }

    return [];
  }

  Future<void> save(Community community) async {
    final all = await loadAll();
    final index = all.indexWhere((w) => w.id == community.id);
    if (index >= 0) {
      all[index] = community;
    } else {
      all.add(community);
    }
    await _saveList(all);
  }

  Future<void> remove(String id) async {
    final all = await loadAll();
    all.removeWhere((w) => w.id == id);
    await _saveList(all);
  }

  Future<String?> loadActiveId() async {
    return _read(_keyActiveId);
  }

  Future<void> saveActiveId(String id) async {
    await _secure.write(key: _keyActiveId, value: id);
  }

  Future<void> clearActiveId() async {
    await _secure.delete(key: _keyActiveId);
  }

  List<Community> _decodeList(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((entry) => Community.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  Future<void> _saveList(List<Community> communities) async {
    final json = jsonEncode(communities.map((item) => item.toJson()).toList());
    await _secure.write(key: _keyCommunities, value: json);
  }
}
