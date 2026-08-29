import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/database/offline_database.dart';
import 'package:moonfin/data/repositories/offline_repository.dart';
import 'package:moonfin/data/services/download_notification_service.dart';
import 'package:moonfin/data/services/download_service.dart';
import 'package:moonfin/data/services/storage_path_service.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeStoragePathService extends StoragePathService {
  final Directory dir;
  _FakeStoragePathService(this.dir);

  @override
  Future<Directory> getOfflineRoot() async => dir;
}

class _FakeItemsApi implements ItemsApi {
  @override
  Future<Map<String, dynamic>> getItem(
    String itemId, {
    String? mediaSourceId,
    String? fields,
  }) async => throw StateError('recovery must not need the server');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopNotificationService extends DownloadNotificationService {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> showProgress({
    required String itemName,
    double? progress,
    int? batchTotal,
    int? batchCompleted,
  }) async {}

  @override
  Future<void> showComplete({
    required String itemName,
    int batchTotal = 0,
  }) async {}

  @override
  Future<void> showError({
    required String itemName,
    required String error,
  }) async {}

  @override
  Future<void> showRemoteMessage({
    required String text,
    String? header,
  }) async {}

  @override
  Future<void> dismiss() async {}
}

class _FakeClient implements MediaServerClient {
  @override
  ItemsApi get itemsApi => _FakeItemsApi();

  @override
  String? get accessToken => 'test-token';

  @override
  String get baseUrl => 'http://127.0.0.1:1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An EBML (mkv) file of [size] bytes, so completion validation passes.
Uint8List _mkvBytes(int size) {
  final bytes = Uint8List(size);
  bytes[0] = 0x1A;
  bytes[1] = 0x45;
  bytes[2] = 0xDF;
  bytes[3] = 0xA3;
  return bytes;
}

void main() {
  late OfflineDatabase db;
  late OfflineRepository repo;
  late Directory tempDir;
  late DownloadService service;

  const itemId = 'movie-1';
  const size = 4096;
  final itemData = <String, dynamic>{
    'Id': itemId,
    'Type': 'Movie',
    'Name': 'Recovered',
    'ProductionYear': 2020,
    'MediaSources': [
      {'Id': 'source-1', 'Container': 'mkv', 'Size': size},
    ],
  };

  Future<File> writeFile(int bytes) async {
    final file = File('${tempDir.path}/Movies/Recovered (2020)/Recovered.mkv');
    await file.parent.create(recursive: true);
    return file.writeAsBytes(_mkvBytes(bytes));
  }

  Future<void> insertRow({
    required String quality,
    int status = 1,
  }) async {
    await repo.upsertItem(
      DownloadedItemsCompanion(
        itemId: const Value(itemId),
        serverId: const Value('http://server'),
        type: const Value('Movie'),
        name: const Value('Recovered'),
        metadataJson: Value(jsonEncode(itemData)),
        downloadStatus: Value(status),
        qualityPreset: Value(quality),
      ),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    final store = PreferenceStore();
    await store.init();

    tempDir = await Directory.systemTemp.createTemp('moonfin_recovery_test');
    db = OfflineDatabase(DatabaseConnection(NativeDatabase.memory()));
    repo = OfflineRepository(db);

    final getIt = GetIt.instance;
    getIt.registerSingleton<UserPreferences>(UserPreferences(store));
    getIt.registerSingleton<StoragePathService>(
      _FakeStoragePathService(tempDir),
    );
    getIt.registerSingleton<OfflineRepository>(repo);

    service = DownloadService(_FakeClient(), _NoopNotificationService());
  });

  tearDown(() async {
    service.dispose();
    await GetIt.instance.reset();
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('a finished file is adopted instead of reset', () async {
    await writeFile(size);
    await insertRow(quality: 'original');

    await service.recoverIncompleteDownloads();
    // The completion path fires its post tasks unawaited; let them run to
    // their catches inside this test instead of after the teardown.
    await pumpEventQueue();

    final row = await repo.getItem(itemId);
    expect(row, isNotNull);
    expect(row!.downloadStatus, 2);
    expect(
      row.localFilePath,
      '${tempDir.path}/Movies/Recovered (2020)/Recovered.mkv',
    );
    expect(await File(row.localFilePath!).length(), size);
  });

  test('a partial file is not adopted and resets like before', () async {
    await writeFile(1000);
    await insertRow(quality: 'original');

    await service.recoverIncompleteDownloads();

    final row = await repo.getItem(itemId);
    expect(row!.downloadStatus, 0);
    expect(row.localFilePath, isNull);
  });

  test('a missing file resets to not-downloaded', () async {
    await insertRow(quality: 'original');

    await service.recoverIncompleteDownloads();

    final row = await repo.getItem(itemId);
    expect(row!.downloadStatus, 0);
  });

  test('a transcoded row is never adopted, even with a full file', () async {
    await writeFile(size);
    await insertRow(quality: 'high1080p');

    await service.recoverIncompleteDownloads();

    final row = await repo.getItem(itemId);
    expect(row!.downloadStatus, 3);
    expect(row.localFilePath, isNull);
  });

  test('a row demoted to failed during a storage blip is healed', () async {
    await writeFile(size);
    await insertRow(quality: 'original');
    await repo.setLocalFilePath(
      itemId,
      '${tempDir.path}/Movies/Recovered (2020)/Recovered.mkv',
      fileSize: size,
    );
    await repo.updateDownloadStatus(itemId, 3, error: 'File not found');

    await service.recoverIncompleteDownloads();
    await pumpEventQueue();

    final row = await repo.getItem(itemId);
    expect(row!.downloadStatus, 2);
    expect(row.localFilePath, isNotNull);
  });

  test('a reset row whose file survived the reset is healed', () async {
    await writeFile(size);
    await insertRow(quality: 'original');
    await repo.updateDownloadStatus(itemId, 0);

    await service.recoverIncompleteDownloads();
    await pumpEventQueue();

    final row = await repo.getItem(itemId);
    expect(row!.downloadStatus, 2);
    expect(row.localFilePath, isNotNull);
  });

  test('a completed row is not demoted when its file is missing', () async {
    await insertRow(quality: 'original', status: 2);
    await repo.setLocalFilePath(
      itemId,
      '${tempDir.path}/Movies/Recovered (2020)/Recovered.mkv',
      fileSize: size,
    );

    // No file exists; the row must survive a transient blip untouched so
    // the offline resolver can report it on demand.
    await service.recoverIncompleteDownloads();

    final row = await repo.getItem(itemId);
    expect(row!.downloadStatus, 2);
  });
}
