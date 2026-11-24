import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    return _restoring.putIfAbsent(key, () async {
      try {
        return await _restore(
          source,
          destination,
          refreshJre:
              relative.startsWith('jvm/') &&
              !relative.startsWith('jvm/native/') &&
              _isStandard(bundle),
        );
      } finally {
        _restoring.remove(key);
      }
    });
  }

  static Future<bool> _restore(
    Directory source,
    Directory destination, {
    required bool refreshJre,
  }) async {
    final manifest = File(p.join(source.path, 'bundle.json'));
    if (!await manifest.exists()) return false;
    final data = jsonDecode(await manifest.readAsString()) as Map;
    final files = Map<String, dynamic>.from(data['files'] as Map);
    final required = (data['required'] as List).cast<String>();
    final marker = File(p.join(destination.path, '.bundled-runtime'));
    if (await marker.exists() &&
        await marker.readAsString() == data['revision'] &&
        required.every((name) {
          final file = File(p.join(destination.path, name));
          return file.existsSync() && file.lengthSync() == files[name];
        })) {
      return true;
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
    await marker.writeAsString(data['revision'] as String, flush: true);
    return true;
  }
}
