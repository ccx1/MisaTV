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

  static Future<void> initialize(String supportPath) async {
    if (!Platform.isWindows) return;
    final ready = File(p.join(root.path, 'ready.json'));
    if (!await ready.exists()) return;
    final versions = jsonDecode(await ready.readAsString()) as Map;
    for (final relative in [
      'jvm/${versions['jvm']}',
      'jvm/native/${versions['guard']}',
      'python/${versions['python']}',
      'mpv-yaozhi',
    ]) {
      if (!await restore(relative, Directory(p.join(supportPath, relative)))) {
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
    final source = Directory(p.join((bundleRoot ?? root).path, relative));
    if (!File(p.join(source.path, 'bundle.json')).existsSync()) {
      return Future.value(false);
    }
    final key = '${source.path}|${destination.path}';
    return _restoring.putIfAbsent(key, () async {
      try {
        return await _restore(source, destination);
      } finally {
        _restoring.remove(key);
      }
    });
  }

  static Future<bool> _restore(Directory source, Directory destination) async {
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
