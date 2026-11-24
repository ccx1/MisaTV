import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/bundled_runtime.dart';

void main() {
  late Directory temp;
  late Directory source;
  late Directory target;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('misatv-bundled-');
    source = Directory('${temp.path}/bundle/python/3.11.6');
    source.createSync(recursive: true);
    target = Directory('${temp.path}/readonly-appdata/python/3.11.6');
    for (final name in ['python.exe', 'Lib/site-packages/requests.py']) {
      final file = File('${source.path}/$name');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('bundled-$name');
    }
    File('${source.path}/bundle.json').writeAsStringSync(
      jsonEncode({
        'revision': 'test-v1',
        'files': {
          'python.exe': File('${source.path}/python.exe').lengthSync(),
          'Lib/site-packages/requests.py': File(
            '${source.path}/Lib/site-packages/requests.py',
          ).lengthSync(),
        },
        'required': ['python.exe'],
      }),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<bool> restore() => BundledRuntime.restore(
    'python/3.11.6',
    target,
    bundleRoot: Directory('${temp.path}/bundle'),
  );

  test('首次离线初始化使用独立数据目录，保留随包原件', () async {
    expect(await restore(), isTrue);
    expect(
      File('${target.path}/python.exe').readAsStringSync(),
      'bundled-python.exe',
    );
    expect(File('${source.path}/python.exe').existsSync(), isTrue);
    expect(
      File('${target.path}/.bundled-runtime').readAsStringSync(),
      'test-v1',
    );
  });

  test('并发恢复共享任务并补齐中断的复制，保留用户配置', () async {
    target.createSync(recursive: true);
    final custom = File('${target.path}/Lib/site-packages/requests.py');
    custom.parent.createSync(recursive: true);
    custom.writeAsStringSync('user settings');
    final first = restore();
    final second = restore();
    expect(identical(first, second), isTrue);
    expect(await first, isTrue);
    expect(custom.readAsStringSync(), 'user settings');
    expect(File('${target.path}/python.exe').existsSync(), isTrue);
  });

  test('工作副本被另一窗口锁定时异步等待，释放后恢复', () async {
    target.createSync(recursive: true);
    final lock = File('${target.path}/.bundled-runtime.lock')
        .openSync(mode: FileMode.append);
    lock.lockSync();
    final task = restore();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File('${target.path}/python.exe').existsSync(), isFalse);
    } finally {
      lock.closeSync();
      await task;
    }
    expect(await task, isTrue);
    expect(File('${target.path}/python.exe').existsSync(), isTrue);
  }, skip: !Platform.isWindows);

  test('已有标记但程序损坏时从随包原件恢复', () async {
    await restore();
    File('${target.path}/python.exe').writeAsStringSync('broken');
    expect(await restore(), isTrue);
    expect(
      File('${target.path}/python.exe').readAsStringSync(),
      'bundled-python.exe',
    );
  });

  test('损坏的随包文件不写成功标记，修复后可以重试', () async {
    final file = File('${source.path}/python.exe');
    file.writeAsStringSync('broken');
    await expectLater(restore(), throwsStateError);
    expect(File('${target.path}/.bundled-runtime').existsSync(), isFalse);
    file.writeAsStringSync('bundled-python.exe');
    expect(await restore(), isTrue);
  });

  test('源码构建没有内置包时沿用原安装流程', () async {
    File('${source.path}/bundle.json').deleteSync();
    expect(await restore(), isFalse);
    expect(target.existsSync(), isFalse);
  });
}
