import 'update_service.dart';

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
  @override
  String toString() => '已取消下载';
}

/// Web 版不支持应用内更新下载（浏览器无法替换正在运行的前端资源）。
class UpdateDownloader {
  static bool canInstallWindows(AppRelease release) => false;

  static Future<void> installWindows(
    AppRelease release, {
    required bool skipDelta,
    required void Function(String status, bool installing) onStatus,
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) {
    throw UnsupportedError('Web 版请通过 Release 页面下载新版本');
  }

  static Future<String> download(
    AppRelease release, {
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) {
    throw UnsupportedError('Web 版请通过 Release 页面下载新版本');
  }

  static Future<void> revealDownload(String path) async {}
}
