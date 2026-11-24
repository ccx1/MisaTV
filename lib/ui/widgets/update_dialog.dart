import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_version.dart';
import '../../core/errors/app_error.dart';
import '../../core/logging/app_log.dart';
import '../../services/update/update_download.dart';
import '../../services/update/update_service.dart';

/// 弹出「发现新版本」对话框：看更新内容，然后下载 / 走网盘 / 稍后提醒。
Future<void> showUpdateDialog(
  BuildContext context,
  AppRelease release, {
  bool fallbackToFull = false,
  bool installFailed = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => UpdateDialog(
      release: release,
      fallbackToFull: fallbackToFull,
      installFailed: installFailed,
    ),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.release,
    this.fallbackToFull = false,
    this.installFailed = false,
  });

  final AppRelease release;
  final bool fallbackToFull;
  final bool installFailed;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;
  bool _installing = false;
  bool _cancelRequested = false;
  String? _downloadStatus;
  int _received = 0;
  int _total = 0;
  String? _error;
  String? _savedPath;

  AppRelease get _release => widget.release;
  bool get _canInstall => UpdateDownloader.canInstallWindows(_release);
  bool get _canDownload =>
      _canInstall || _release.downloadUrl.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.installFailed) _error = '安装失败，已恢复旧版';
    if (widget.fallbackToFull) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startDownload();
      });
    }
  }

  Future<void> _open(String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw '系统没有可用的浏览器';
    } catch (e) {
      AppLog.w('update', '打开下载地址失败：$e');
      messenger?.showSnackBar(SnackBar(content: Text('打不开链接：$e')));
    }
  }

  Future<void> _startDownload() async {
    if (_downloading) return;
    // Web 版没有文件系统，也没有可执行的应用内替换流程，直接打开发布页。
    if (!_canDownload || kIsWeb) {
      await _open(_release.openUrl);
      return;
    }
    setState(() {
      _downloading = true;
      _installing = false;
      _cancelRequested = false;
      _received = 0;
      _total = _release.assetSize;
      _downloadStatus = null;
      _error = null;
      _savedPath = null;
    });
    try {
      bool isCancelled() => !mounted || _cancelRequested;
      void onProgress(int received, int total) {
        if (!mounted) return;
        setState(() {
          _received = received;
          if (total > 0) _total = total;
        });
      }

      if (_canInstall) {
        await UpdateDownloader.installWindows(
          _release,
          skipDelta: widget.fallbackToFull || widget.installFailed,
          onStatus: (status, installing) {
            if (mounted) {
              setState(() {
                _downloadStatus = status;
                _installing = installing;
              });
            }
          },
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
        return;
      }
      onProgress(0, _release.assetSize);
      final path = await UpdateDownloader.download(
        _release,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _savedPath = path;
      });
    } on UpdateDownloadCancelled {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _cancelRequested = false;
      });
    } catch (e) {
      AppLog.w('update', '更新失败：$e');
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e is StateError ? e.message : describeAppError(e).message;
      });
    }
  }

  Future<void> _reveal() async {
    final path = _savedPath;
    if (path == null) return;
    await UpdateDownloader.revealDownload(path);
  }

  static String _formatBytes(int value) {
    if (value <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Widget _progress(ThemeData theme) {
    final ratio = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final percent = ratio == null
        ? ''
        : ' · ${(ratio * 100).toStringAsFixed(0)}%';
    final size = _total > 0
        ? '${_formatBytes(_received)} / ${_formatBytes(_total)}$percent'
        : '已下载 ${_formatBytes(_received)}';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: ratio),
          const SizedBox(height: 6),
          Text(
            size,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = _release.notes.isEmpty ? '本次发布没有填写更新说明。' : _release.notes;
    final savedPath = _savedPath;
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.system_update_alt_rounded,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Flexible(child: Text('发现新版本 v${_release.version}')),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '当前版本 v$kAppVersion  ·  最新 v${_release.version}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: SelectableText(
                  notes,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                ),
              ),
            ),
            if (_downloading && _downloadStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_downloadStatus!),
              ),
            if (_downloading) _progress(theme),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '$_error\n'
                  '可重试，或用「网盘下载」手动获取。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    height: 1.5,
                  ),
                ),
              ),
            if (savedPath != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(
                        '已下载到 $savedPath',
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      actions: [
        if (_downloading)
          TextButton(
            onPressed: _installing
                ? null
                : () => setState(() => _cancelRequested = true),
            child: const Text('取消下载'),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后提醒'),
          ),
        if (!_downloading && savedPath == null)
          TextButton.icon(
            onPressed: () => _open(kUpdateNetdiskUrl),
            icon: const Icon(Icons.cloud_outlined, size: 18),
            label: const Text('网盘下载'),
          ),
        if (savedPath != null)
          FilledButton.icon(
            onPressed: _reveal,
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('打开文件夹'),
          )
        else if (_downloading)
          FilledButton(
            onPressed: null,
            child: Text(_installing ? '安装中…' : '下载中…'),
          )
        else
          FilledButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(
              !_canDownload
                  ? '打开发布页'
                  : _canInstall
                  ? (_error == null ? '下载并安装' : '重试更新')
                  : (_error == null ? '下载' : '重试下载'),
            ),
          ),
      ],
    );
  }
}
