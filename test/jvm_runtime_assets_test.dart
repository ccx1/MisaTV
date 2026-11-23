import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jvm/jvm_runtime.dart';

class _JvmBundle extends CachingAssetBundle {
  final assets = <String, ByteData>{};
  var loads = 0;

  _JvmBundle() {
    for (final file in Directory('assets/jvm').listSync().whereType<File>()) {
      if (!file.path.endsWith('.jar')) continue;
      final name = file.uri.pathSegments.last;
      assets['assets/jvm/$name'] = ByteData.sublistView(file.readAsBytesSync());
    }
  }

  @override
  Future<ByteData> load(String key) async {
    loads++;
    final data = assets[key];
    if (data == null) throw FlutterError('Unable to load asset: "$key".');
    return data;
  }
}

void main() {
  late Directory directory;
  late _JvmBundle bundle;
  late JvmRuntime runtime;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('misatv-jvm-assets-');
    bundle = _JvmBundle();
    runtime = JvmRuntime.forTesting(directory: directory, bundle: bundle);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('重新检测可识别另一个窗口安装的运行时', () async {
    expect(await runtime.installed(), isFalse);
    for (final name in ['jre/bin', 'd2j', 'libs', 'shims']) {
      Directory('${directory.path}/$name').createSync(recursive: true);
    }
    File('${directory.path}/jre/bin/java.exe').writeAsBytesSync([1]);
    expect(await runtime.installed(refresh: true), isTrue);
    File('${directory.path}/jre/bin/java.exe').deleteSync();
    expect(await runtime.installed(refresh: true), isFalse);
  });

  test('无预解包 JAR 的发布包仍能安装兼容层并记录成功', () async {
    await runtime.ensureShims(force: true);

    expect(
      File('${directory.path}/shims/stubs.jar').lengthSync(),
      greaterThan(0),
    );
    expect(
      File('${directory.path}/shims/native-bridge.jar').existsSync(),
      isTrue,
    );
    expect(File('${directory.path}/shims/.bundled-rev').existsSync(), isTrue);
    expect(
      File('${directory.path}/shell-shim/real/ftyshinidie.jar').existsSync(),
      isFalse,
    );

    final loads = bundle.loads;
    await runtime.ensureShims();
    expect(bundle.loads, loads, reason: '可选资产缺失不应导致每次调用都刷新');
  });

  test('可选资产缺失时保留用户已有的真实实现', () async {
    final real = File('${directory.path}/shell-shim/real/ftyshinidie.jar');
    real.parent.createSync(recursive: true);
    real.writeAsBytesSync([0x50, 0x4b, 1, 2, 3]);

    await runtime.ensureShims(force: true);

    expect(real.readAsBytesSync(), [0x50, 0x4b, 1, 2, 3]);
  });

  test('必需资产缺失时失败且不写入成功标记', () async {
    bundle.assets.remove('assets/jvm/stubs.jar');

    await expectLater(
      runtime.ensureShims(force: true),
      throwsA(isA<FlutterError>()),
    );
    expect(File('${directory.path}/shims/.bundled-rev').existsSync(), isFalse);
  });

  test('内置真实实现存在时复制 ByteData 的有效区间', () async {
    final padded = Uint8List.fromList([99, 0x50, 0x4b, 3, 4, 88]);
    bundle.assets['assets/jvm/shell-real/ftyshinidie.jar'] =
        ByteData.sublistView(padded, 1, 5);

    await runtime.ensureShims(force: true);

    expect(
      File('${directory.path}/shell-shim/real/ftyshinidie.jar')
          .readAsBytesSync(),
      [0x50, 0x4b, 3, 4],
    );
  });

  test('升级后替换旧 stubs，补齐原生解包所需的 ContextWrapper', () async {
    final stubs = File('${directory.path}/shims/stubs.jar');
    stubs.parent.createSync(recursive: true);
    stubs.writeAsBytesSync([1]);
    File('${directory.path}/shims/.bundled-rev').writeAsStringSync('15');

    await runtime.ensureShims();

    expect(
      stubs.readAsBytesSync(),
      File('assets/jvm/stubs.jar').readAsBytesSync(),
    );
    expect(
      File('${directory.path}/shims/.bundled-rev').readAsStringSync(),
      '16',
    );
  });
}
