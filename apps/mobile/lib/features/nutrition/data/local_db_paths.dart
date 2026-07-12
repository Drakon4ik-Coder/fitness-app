import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Per-user SQLite file naming (KAN-64).
///
/// Both local DBs are namespaced by server user id (`<base>_u<id>.db`) so a
/// device can hold several accounts' data side by side: logout keeps the
/// files (an unsynced offline outbox survives re-login instead of being
/// wiped), and a leftover outbox can never replay into another account
/// because that account opens different files.

/// Resolves the SQLite path for [baseName] under [directoryPath], adopting
/// the pre-namespacing shared file on first scoped open.
///
/// The legacy nutrition DB can only belong to the signing-in user (the old
/// wipe-on-logout invariant emptied it for anyone else), and the legacy foods
/// DB was shared across users anyway — so renaming both into the current
/// user's namespace preserves exactly what this device showed yesterday.
Future<String> resolveUserDbPath({
  required String directoryPath,
  required String baseName,
  required int? userId,
}) async {
  if (userId == null) return '$directoryPath/$baseName.db';
  final scopedPath = '$directoryPath/${baseName}_u$userId.db';
  final legacyPath = '$directoryPath/$baseName.db';
  if (!File(scopedPath).existsSync() && File(legacyPath).existsSync()) {
    await _renameWithSidecars(legacyPath, scopedPath);
  }
  return scopedPath;
}

/// Moves a SQLite file together with its `-wal`/`-shm`/`-journal` sidecars —
/// renaming only the main file would silently drop WAL-resident writes.
Future<void> _renameWithSidecars(String fromPath, String toPath) async {
  await File(fromPath).rename(toPath);
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final sidecar = File('$fromPath$suffix');
    if (sidecar.existsSync()) {
      await sidecar.rename('$toPath$suffix');
    }
  }
}

/// Deletes the DB files of users other than [currentUserId], keeping the
/// [keepUsers] most recently touched accounts (including the current one).
///
/// Storage hygiene for shared devices: without a cap, every account that ever
/// signed in would keep its food log on disk forever. Best-effort by design —
/// callers fire-and-forget it at startup.
Future<void> evictStaleUserDbs({
  required int currentUserId,
  int keepUsers = 3,
  String? directoryPath,
}) async {
  final dirPath =
      directoryPath ?? (await getApplicationDocumentsDirectory()).path;
  final pattern = RegExp(r'^[a-z_]+_u(\d+)\.db$');

  // Newest activity per user id, from the DB files' own mtimes.
  final lastTouched = <int, DateTime>{};
  final filesByUser = <int, List<File>>{};
  await for (final item in Directory(dirPath).list()) {
    if (item is! File) continue;
    final name = item.uri.pathSegments.last;
    final match = pattern.firstMatch(name);
    if (match == null) continue;
    final userId = int.parse(match.group(1)!);
    filesByUser.putIfAbsent(userId, () => []).add(item);
    final modified = item.lastModifiedSync();
    final known = lastTouched[userId];
    if (known == null || modified.isAfter(known)) {
      lastTouched[userId] = modified;
    }
  }

  final ranked = lastTouched.keys.toList()
    ..sort((a, b) => lastTouched[b]!.compareTo(lastTouched[a]!));
  final others = ranked.where((id) => id != currentUserId).take(keepUsers - 1);
  final keep = <int>{currentUserId, ...others};

  for (final entry in filesByUser.entries) {
    if (keep.contains(entry.key)) continue;
    for (final file in entry.value) {
      // Sidecars match the pattern's prefix + suffix, so delete them too.
      for (final path in [
        file.path,
        '${file.path}-wal',
        '${file.path}-shm',
        '${file.path}-journal',
      ]) {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      }
    }
  }
}
