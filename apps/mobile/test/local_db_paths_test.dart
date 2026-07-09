import 'dart:io';

import 'package:fitness_app/features/nutrition/data/local_db_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('local_db_paths_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  File file(String name, {String content = 'x'}) {
    final f = File('${dir.path}/$name');
    f.writeAsStringSync(content);
    return f;
  }

  group('resolveUserDbPath', () {
    test('null user id keeps the legacy shared path', () async {
      final path = await resolveUserDbPath(
        directoryPath: dir.path,
        baseName: 'foods',
        userId: null,
      );
      expect(path, '${dir.path}/foods.db');
    });

    test(
      'adopts the legacy file (and sidecars) on first scoped open',
      () async {
        file('nutrition_cache.db', content: 'main');
        file('nutrition_cache.db-wal', content: 'wal');
        file('nutrition_cache.db-shm', content: 'shm');

        final path = await resolveUserDbPath(
          directoryPath: dir.path,
          baseName: 'nutrition_cache',
          userId: 42,
        );

        expect(path, '${dir.path}/nutrition_cache_u42.db');
        expect(File(path).readAsStringSync(), 'main');
        expect(File('$path-wal').readAsStringSync(), 'wal');
        expect(File('$path-shm').readAsStringSync(), 'shm');
        expect(File('${dir.path}/nutrition_cache.db').existsSync(), isFalse);
        expect(
          File('${dir.path}/nutrition_cache.db-wal').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'never overwrites an existing scoped file with the legacy one',
      () async {
        file('foods.db', content: 'legacy');
        file('foods_u42.db', content: 'mine');

        final path = await resolveUserDbPath(
          directoryPath: dir.path,
          baseName: 'foods',
          userId: 42,
        );

        expect(File(path).readAsStringSync(), 'mine');
        // The legacy file stays for whichever user opens scoped first.
        expect(File('${dir.path}/foods.db').existsSync(), isTrue);
      },
    );

    test('no files at all: just returns the scoped path', () async {
      final path = await resolveUserDbPath(
        directoryPath: dir.path,
        baseName: 'foods',
        userId: 1,
      );
      expect(path, '${dir.path}/foods_u1.db');
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('evictStaleUserDbs', () {
    test('keeps current + most recent others, deletes the rest', () async {
      final now = DateTime.now();
      for (final (userId, age) in [(1, 40), (2, 30), (3, 20), (4, 10)]) {
        for (final base in ['nutrition_cache', 'foods']) {
          file(
            '${base}_u$userId.db',
          ).setLastModifiedSync(now.subtract(Duration(days: age)));
        }
      }
      file('foods_u1.db-wal'); // sidecar of an evictee

      // Current user is the *oldest* — must survive regardless of mtime.
      await evictStaleUserDbs(
        currentUserId: 1,
        keepUsers: 3,
        directoryPath: dir.path,
      );

      bool exists(String name) => File('${dir.path}/$name').existsSync();
      expect(exists('foods_u1.db'), isTrue);
      expect(exists('foods_u4.db'), isTrue);
      expect(exists('foods_u3.db'), isTrue);
      expect(exists('foods_u2.db'), isFalse);
      expect(exists('nutrition_cache_u2.db'), isFalse);
      expect(exists('foods_u1.db-wal'), isTrue); // kept with its owner
    });

    test('ignores unscoped and unrelated files', () async {
      file('foods.db');
      file('nutrition_cache.db');
      file('something_else.txt');
      file('foods_u9.db');

      await evictStaleUserDbs(
        currentUserId: 9,
        keepUsers: 1,
        directoryPath: dir.path,
      );

      expect(File('${dir.path}/foods.db').existsSync(), isTrue);
      expect(File('${dir.path}/nutrition_cache.db').existsSync(), isTrue);
      expect(File('${dir.path}/something_else.txt').existsSync(), isTrue);
      expect(File('${dir.path}/foods_u9.db').existsSync(), isTrue);
    });
  });
}
