import 'package:background_downloader/background_downloader.dart' as bgd;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Stands in for the platform side of path_provider, which Task.split
/// consults when mapping a non-Android save path onto a task location.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => '';

  @override
  Future<String?> getApplicationSupportPath() async => '';

  @override
  Future<String?> getApplicationDocumentsPath() async => '';
}

/// Tests for the plugin task used for media downloads. Android must target
/// the destination with a file:// UriDownloadTask, which the native runner
/// writes to directly: a temp-then-move task's completing Files.move can
/// degrade to a ~1 MB/s userspace copy on TV flash, parking multi-gigabyte
/// downloads in "Finalizing" for tens of minutes.
void main() {
  const savePath =
      '/storage/emulated/0/Android/data/org.moonfin.androidtv.beta/files/'
      'Moonfin/TV/Meridian Drift/Season 02/S02E08 - Signal Fade.mkv';

  Future<bgd.DownloadTask> build({required bool isAndroid}) {
    return buildMediaDownloadTask(
      isAndroid: isAndroid,
      taskId: 'task-1',
      url: 'https://jelly.example.com/item',
      savePath: savePath,
      resumable: true,
      headers: const {'Authorization': 'token'},
      requiresWiFi: false,
      metaData: '{"itemId":"item-1"}',
      displayName: 'Signal Fade',
    );
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
  });

  test('Android writes straight to the destination via a file Uri task', () async {
    final task = await build(isAndroid: true);

    expect(task, isA<bgd.UriDownloadTask>());
    final uriTask = task as bgd.UriDownloadTask;
    // The runner opens its output stream on the directory Uri plus the
    // unpacked filename, so those two must reproduce the save path exactly,
    // spaces and all.
    expect(uriTask.directoryUri?.scheme, 'file');
    expect(
      uriTask.directoryUri?.toFilePath(windows: false),
      '/storage/emulated/0/Android/data/org.moonfin.androidtv.beta/files/'
      'Moonfin/TV/Meridian Drift/Season 02',
    );
    expect(uriTask.filename, 'S02E08 - Signal Fade.mkv');
  });

  test(
    'the packed fileUri is single-encoded, so the runner decoding it once '
    'resolves the real save path',
    () async {
      final task = await build(isAndroid: true);
      final uriTask = task as bgd.UriDownloadTask;

      expect(uriTask.fileUri?.scheme, 'file');
      // The plugin's constructor double-encodes this Uri (it re-encodes the
      // directory's already-encoded path), which on device made the runner
      // open a literal "Season%2002" path and fail with ENOENT. One decode
      // of the packed fileUri must yield the exact save path.
      expect(
        Uri.decodeComponent(uriTask.fileUri!.path),
        '/storage/emulated/0/Android/data/org.moonfin.androidtv.beta/files/'
        'Moonfin/TV/Meridian Drift/Season 02/S02E08 - Signal Fade.mkv',
      );
    },
  );

  test('Android Uri tasks do not offer pause, since they cannot resume', () async {
    final task = await build(isAndroid: true);

    expect(task.allowPause, isFalse);
    expect(task.retries, 3);
  });

  test('transcoded qualities do not retry on any platform', () async {
    final task = await buildMediaDownloadTask(
      isAndroid: true,
      taskId: 'task-1',
      url: 'https://jelly.example.com/item',
      savePath: savePath,
      resumable: false,
      headers: const {},
      requiresWiFi: false,
      metaData: '',
      displayName: 'Signal Fade',
    );

    expect(task.retries, 0);
  });

  test('other platforms keep the temp-then-move task', () async {
    final task = await build(isAndroid: false);

    expect(task, isA<bgd.DownloadTask>());
    expect(task, isNot(isA<bgd.UriDownloadTask>()));
    expect(task.allowPause, isTrue);
  });
}
