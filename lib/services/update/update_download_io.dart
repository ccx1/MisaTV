import 'dart:async';
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
  static bool _updatingWindows = false;

  static String _windowsVariant(Directory installDir) {
    final runtimes = p.join(installDir.path, 'runtimes');
    if (!File(p.join(runtimes, 'ready.json')).existsSync()) return 'lite';
    return File(p.join(runtimes, 'standard')).existsSync()
        ? 'standard'
        : 'full';
  }

  static bool canInstallWindows(AppRelease release) {
    if (!Platform.isWindows) return false;
    final variant = _windowsVariant(File(Platform.resolvedExecutable).parent);
    return release.windowsDeltas.containsKey(variant) ||
        release.windowsPackages.containsKey(variant);
  }

  static Future<void> installWindows(
    AppRelease release, {
    required bool skipDelta,
    required void Function(String status, bool installing) onStatus,
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_updatingWindows) throw StateError('已有更新任务正在运行');
    final exe = File(Platform.resolvedExecutable);
    final helper = File(p.join(exe.parent.path, 'apply_windows_delta.ps1'));
    _updatingWindows = true;
    try {
      if (!await helper.exists()) throw StateError('应用目录缺少更新脚本');
      final variant = _windowsVariant(exe.parent);
      final delta = skipDelta ? null : release.windowsDeltas[variant];
      var deltaFailed = skipDelta;
      if (delta != null) {
        try {
          await _applyWindowsPackage(
            release.tag,
            delta,
            variant,
            exe,
            helper,
            isDelta: true,
            onStatus: onStatus,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          return;
        } on UpdateDownloadCancelled {
          rethrow;
        } catch (error) {
          AppLog.w('update', '差异更新失败，改用整包：$error');
          deltaFailed = true;
          if (isCancelled?.call() ?? false) {
            throw const UpdateDownloadCancelled();
          }
        }
      }
      final package = release.windowsPackages[variant];
      if (package == null) throw StateError('该版本缺少与当前安装包型匹配且可校验的整包');
      await _applyWindowsPackage(
        release.tag,
        package,
        variant,
        exe,
        helper,
        isDelta: false,
        deltaFailed: deltaFailed,
        onStatus: onStatus,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } finally {
      _updatingWindows = false;
    }
  }

  static Future<void> _applyWindowsPackage(
    String tag,
    UpdateAsset asset,
    String variant,
    File exe,
    File helper, {
    required bool isDelta,
    bool deltaFailed = false,
    required void Function(String status, bool installing) onStatus,
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final archiveName = isDelta ? 'delta.zip' : 'full.zip';
    Directory? session;
    var workerStarted = false;
    var workerFailed = false;
    int? workerExitCode;
    try {
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      final temp = session = await Directory.systemTemp.createTemp(
        'misatv-update-',
      );
      onStatus(
        isDelta
            ? '正在下载差异包'
            : deltaFailed
            ? '差异更新失败，正在下载整包'
            : '正在下载整包',
        false,
      );
      onProgress(0, asset.size);
      await _downloadAsset(
        asset,
        File(p.join(temp.path, archiveName)),
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      onStatus('正在校验并准备安装，完成后将自动重启', false);

      // 更新时可以替换安装目录里的原脚本。
      final script = await helper.copy(p.join(temp.path, 'apply.ps1'));
      final powershell = p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      // Windows PowerShell 在 detached 模式会退出，常规子进程可在应用退出后继续安装。
      final worker = await Process.start(powershell, [
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
        exe.parent.path,
        '-ExeName',
        p.basename(exe.path),
        '-ParentPid',
        '$pid',
        '-From',
        'v$kAppVersion',
        '-To',
        tag,
        '-Variant',
        variant,
        '-Digest',
        asset.digest.substring('sha256:'.length),
        if (!isDelta) '-FullPackage',
      ]);
      workerStarted = true;
      unawaited(worker.stdout.drain<void>());
      unawaited(worker.stderr.drain<void>());
      unawaited(worker.exitCode.then((code) => workerExitCode = code));
      final ready = File(p.join(temp.path, 'ready'));
      final failed = File(p.join(temp.path, 'failed'));
      Future<void> checkWorker() async {
        if (await failed.exists()) {
          workerFailed = true;
          AppLog.w('update', 'Windows 安装脚本失败：${await failed.readAsString()}');
          throw StateError('无法准备或安装更新，请检查应用目录是否可写');
        }
        if (workerExitCode != null) {
          workerFailed = true;
          throw StateError('Windows 安装脚本提前退出（退出码 $workerExitCode）');
        }
      }

      final elapsed = Stopwatch()..start();
      while (!await ready.exists()) {
        if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
        await checkWorker();
        if (elapsed.elapsed > Duration(minutes: isDelta ? 2 : 10)) {
          throw StateError('准备安装更新超时');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      onStatus('正在关闭应用并安装更新', true);
      await File(p.join(temp.path, 'commit')).writeAsString('', flush: true);
      await closeAppWindow();
      // 正常安装会退出当前进程。如果关窗失败，等待脚本报错。
      elapsed.reset();
      while (elapsed.elapsed < const Duration(seconds: 25)) {
        await checkWorker();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await checkWorker();
      throw StateError('等待应用退出超时，请重试');
    } finally {
      if (session != null) {
        try {
          if (workerStarted && !workerFailed) {
            await File(p.join(session.path, 'cancel')).writeAsString('');
          } else {
            await session.delete(recursive: true);
          }
        } on FileSystemException {
          // 临时目录清理失败不影响重试。
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
