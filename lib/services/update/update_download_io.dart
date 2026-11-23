import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_version.dart';
import '../../core/logging/app_log.dart';
import '../../core/platform/window_service.dart';
import 'update_service.dart';

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
  @override
  String toString() => '已取消下载';
}

/// 应用内更新下载：支持断点续传、大小与 SHA-256 校验。
class UpdateDownloader {
  static bool _applyingDelta = false;

  static Future<bool> tryWindowsDelta(
    AppRelease release, {
    required void Function(int received, int total) onProgress,
    required void Function() onPreparing,
    bool Function()? isCancelled,
  }) async {
    if (!Platform.isWindows || release.windowsDeltas.isEmpty) return false;
    final exe = File(Platform.resolvedExecutable);
    final root = exe.parent;
    final helper = File(p.join(root.path, 'apply_windows_delta.ps1'));
    if (!await helper.exists() || _applyingDelta) return false;
    _applyingDelta = true;
    Directory? session;
    var committed = false;
    var workerStarted = false;
    try {
      final hasRuntimes = await File(
        p.join(root.path, 'runtimes', 'ready.json'),
      ).exists();
      final variant = hasRuntimes ? 'full' : 'lite';
      final asset = release.windowsDeltas[variant];
      if (asset == null) return false;
      final temp = session = await Directory.systemTemp.createTemp(
        'misatv-delta-',
      );
      onProgress(0, asset.size);
      await _downloadAsset(
        asset,
        File(p.join(temp.path, 'delta.zip')),
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      onPreparing();

      // 更新时可以替换安装目录里的原脚本。
      final script = await helper.copy(p.join(temp.path, 'apply.ps1'));
      final powershell = p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      await Process.start(powershell, [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Session',
        temp.path,
        '-Root',
        root.path,
        '-ExeName',
        p.basename(exe.path),
        '-ParentPid',
        '$pid',
        '-From',
        'v$kAppVersion',
        '-To',
        release.tag,
        '-Variant',
        variant,
        '-Digest',
        asset.digest.substring('sha256:'.length),
      ], mode: ProcessStartMode.detached);
      workerStarted = true;
      final ready = File(p.join(temp.path, 'ready'));
      final failed = File(p.join(temp.path, 'failed'));
      final elapsed = Stopwatch()..start();
      while (!await ready.exists()) {
        if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
        if (await failed.exists()) {
          throw StateError(await failed.readAsString());
        }
        if (elapsed.elapsed > const Duration(minutes: 2)) {
          throw StateError('准备差异更新超时');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      await File(p.join(temp.path, 'commit')).writeAsString('', flush: true);
      await closeAppWindow();
      committed = true;
      return true;
    } on UpdateDownloadCancelled {
      rethrow;
    } catch (error) {
      AppLog.w('update', '差异更新失败，改用完整包：$error');
      return false;
    } finally {
      if (!committed) {
        _applyingDelta = false;
        if (session != null) {
          try {
            if (workerStarted) {
              await File(p.join(session.path, 'cancel')).writeAsString('');
            } else {
              await session.delete(recursive: true);
            }
          } on FileSystemException {
            // 临时目录清理失败不影响完整包下载。
          }
        }
      }
    }
  }

  static Future<String> download(
    AppRelease release, {
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final url = release.downloadUrl.trim();
    if (url.isEmpty) throw StateError('该版本没有可直下的安装包');
    final dir = await _downloadDir();
    final name = _safeName(release.assetName, release.version);
    return _downloadAsset(
      (
        name: name,
        url: url,
        size: release.assetSize,
        digest: release.assetDigest,
      ),
      File(p.join(dir.path, name)),
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  static Future<String> _downloadAsset(
    UpdateAsset asset,
    File target, {
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final part = File('${target.path}.part');
    final existing = await part.exists() ? await part.length() : 0;

    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(asset.url));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'MisaTV-updater')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (existing > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw HttpException('下载失败 HTTP ${response.statusCode}');
      }
      final append = response.statusCode == 206 && existing > 0;
      final total =
          (response.contentLength >= 0 ? response.contentLength : 0) +
          (append ? existing : 0);
      final sink = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = append ? existing : 0;
      onProgress(received, total);
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          await sink.flush();
          await sink.close();
          throw const UpdateDownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();

      if (asset.size > 0 && await part.length() != asset.size) {
        await part.delete();
        throw StateError('安装包大小校验失败，请重试');
      }
      final digest = asset.digest.trim().toLowerCase();
      if (digest.startsWith('sha256:')) {
        final expected = digest.substring(7).trim();
        final actual = await sha256.bind(part.openRead()).first;
        if (actual.toString().toLowerCase() != expected) {
          await part.delete();
          throw StateError('安装包 SHA-256 校验失败，请重试');
        }
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      AppLog.i('update', '更新包已下载：${target.path}');
      return target.path;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> revealDownload(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [p.dirname(path)]);
      }
    } catch (e) {
      AppLog.w('update', '打开下载目录失败：$e');
    }
  }

  static Future<Directory> _downloadDir() async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir;
    } catch (_) {
      // 某些平台没有下载目录，回落到临时目录。
    }
    return Directory.systemTemp;
  }

  static String _safeName(String assetName, String version) {
    final raw = assetName.trim().isEmpty
        ? 'MisaTV-$version.zip'
        : assetName.trim();
    return raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
