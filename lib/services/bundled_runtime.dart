import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// 发布包里的运行时原件只读；工作副本放到可写的应用数据目录。
class BundledRuntime {
  BundledRuntime._();

  static final _restoring = <String, Future<bool>>{};

  static Directory get root => Directory(
    p.join(File(Platform.resolvedExecutable).parent.path, 'runtimes'),
  );

  static bool available(String relative) =>
      Platform.isWindows &&
      File(p.join(root.path, relative, 'bundle.json')).existsSync();

  static bool _isStandard(Directory bundle) =>
      File(p.join(bundle.path, 'standard')).existsSync();

  static Directory jvmDirectory(
    String supportPath,
    String version, {
    Directory? bundleRoot,
  }) => Directory(
    p.join(
      supportPath,
      _isStandard(bundleRoot ?? root) ? 'jvm-standard' : 'jvm',
      version,
    ),
  );

  static Future<void> initialize(
    String supportPath, {
    Directory? bundleRoot,
  }) async {
    if (!Platform.isWindows && bundleRoot == null) return;
    final ready = File(p.join((bundleRoot ?? root).path, 'ready.json'));
    if (!await ready.exists()) return;
    final versions = jsonDecode(await ready.readAsString()) as Map;
    final jvmVersion = versions['jvm'] as String;
    final jvmRelative = 'jvm/$jvmVersion';
    for (final relative in [
      jvmRelative,
      'jvm/native/${versions['guard']}',
      'python/${versions['python']}',
      if (versions['mpv'] != null) 'mpv-yaozhi',
    ]) {
      if (!await restore(
        relative,
        relative == jvmRelative
            ? jvmDirectory(supportPath, jvmVersion, bundleRoot: bundleRoot)
            : Directory(p.join(supportPath, relative)),
        bundleRoot: bundleRoot,
      )) {
        throw StateError('内置运行时清单缺失：$relative');
      }
    }
  }

  /// 并发窗口各自调用时也只写完整文件，复制中断后下次会继续补齐。
  static Future<bool> restore(
    String relative,
    Directory destination, {
    Directory? bundleRoot,
  }) {
    if (!Platform.isWindows && bundleRoot == null) return Future.value(false);
    final bundle = bundleRoot ?? root;
    final source = Directory(p.join(bundle.path, relative));
    if (!File(p.join(source.path, 'bundle.json')).existsSync()) {
      return Future.value(false);
    }
    final key = '${source.path}|${destination.path}';
    final refreshJre =
        relative.startsWith('jvm/') &&
        !relative.startsWith('jvm/native/') &&
        _isStandard(bundle);
    return _restoring.putIfAbsent(key, () async {
      try {
        return await Isolate.run(
          () => _restore(source, destination, refreshJre: refreshJre),
        );
      } finally {
        _restoring.remove(key);
      }
    });
  }

  static bool _restore(
    Directory source,
    Directory destination, {
    required bool refreshJre,
  }) {
    final manifest = File(p.join(source.path, 'bundle.json'));
    if (!manifest.existsSync()) return false;
    final data = jsonDecode(manifest.readAsStringSync()) as Map;
    final files = Map<String, dynamic>.from(data['files'] as Map);
    final required = (data['required'] as List).cast<String>().toSet();
    final revision = data['revision'] as String;
    destination.createSync(recursive: true);
    // 主窗口与独立播放器各有 isolate，用文件锁共享同一份工作副本。
    final lock = File(p.join(destination.path, '.bundled-runtime.lock'))
        .openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      _restoreFiles(source, destination, files, required, revision, refreshJre);
      return true;
    } finally {
      lock.closeSync();
    }
  }

  static void _restoreFiles(
    Directory source,
    Directory destination,
    Map<String, dynamic> files,
    Set<String> required,
    String revision,
    bool refreshJre,
  ) {
    final marker = File(p.join(destination.path, '.bundled-runtime'));
    if (marker.existsSync() &&
        marker.readAsStringSync() == revision &&
        required.every((name) {
          final file = File(p.join(destination.path, name));
          return file.existsSync() && file.lengthSync() == files[name];
        })) {
      return;
    }
    final createdDirectories = <String>{};
    for (final entry in files.entries) {
      final input = File(p.join(source.path, entry.key));
      if (!input.existsSync() || input.lengthSync() != entry.value) {
        throw StateError('内置运行时文件缺失或损坏：${input.path}');
      }
      final output = File(p.join(destination.path, entry.key));
      // 保留 MPV 用户配置；损坏的程序文件与缺失文件从随包原件恢复。
      if (output.existsSync() &&
          !(refreshJre && entry.key.startsWith('jre/')) &&
          (!required.contains(entry.key) ||
              output.lengthSync() == entry.value)) {
        continue;
      }
      if (createdDirectories.add(output.parent.path)) {
        output.parent.createSync(recursive: true);
      }
      final temp = File(
        '${output.path}.${pid}_${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        input.copySync(temp.path);
        temp.renameSync(output.path);
      } finally {
        if (temp.existsSync()) temp.deleteSync();
      }
    }
    marker.writeAsStringSync(revision, flush: true);
  }
}
