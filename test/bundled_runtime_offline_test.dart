import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/bundled_runtime.dart';
import 'package:kniephos/services/jvm/arm_bridge_runtime.dart';
import 'package:kniephos/services/jvm/jvm_runtime.dart';
import 'package:kniephos/services/mpv_extension.dart';
import 'package:kniephos/services/py_spider/py_runtime.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _OfflineClient implements HttpClient {
  @override
  set connectionTimeout(Duration? value) {}
  @override
  set autoUncompress(bool value) {}
  @override
  set userAgent(String? value) {}
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('离线运行时不允许网络调用：${invocation.memberName}');
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '真实随包组件在空数据目录离线就绪，安装检查不请求网络',
    () async {
      final temp = Directory.systemTemp.createTempSync('misatv-offline-');
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(temp.path);
      try {
        await HttpOverrides.runZoned(() async {
          final source = Directory('assets/windows-runtimes').absolute;
          await BundledRuntime.initialize(temp.path, bundleRoot: source);
          expect(await JvmRuntime.instance.installed(refresh: true), isTrue);
          await JvmRuntime.instance.ensureInstalled();
          final java = await Process.run(
            await JvmRuntime.instance.javaExecutable(),
            ['-version'],
          );
          expect(java.exitCode, 0);
          expect('${java.stderr}', contains('17.0.'));
          expect(await ArmBridgeRuntime.instance.installed(), isTrue);
          await ArmBridgeRuntime.instance.ensureInstalled();
          expect(await ArmBridgeRuntime.instance.jarPaths(), hasLength(18));
          expect(await PyRuntime.instance.installed(), isTrue);
          await PyRuntime.instance.ensureInstalled();
          expect(await PyRuntime.instance.assetsCurrent(), isTrue);
          expect(await MpvExtension.instance.isInstalled, isTrue);
          expect(
            await MpvExtension.instance.executablePath,
            endsWith('Yaoplayer.exe'),
          );
          expect(await MpvExtension.instance.meta, contains('tag'));
        }, createHttpClient: (_) => _OfflineClient());
      } finally {
        PathProviderPlatform.instance = paths;
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        !File('assets/windows-runtimes/ready.json').existsSync(),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  final standard = Directory('build/windows-runtimes-standard/runtimes');
  test(
    '标准包从空目录离线初始化随包组件',
    () async {
      final support = await Directory.systemTemp.createTemp('misatv-standard-');
      addTearDown(() => support.delete(recursive: true));
      final standardJvm = BundledRuntime.jvmDirectory(
        support.path,
        JvmRuntime.version,
        bundleRoot: standard,
      );
      await HttpOverrides.runZoned(() async {
        await BundledRuntime.initialize(support.path, bundleRoot: standard);
      }, createHttpClient: (_) => _OfflineClient());
      final java = await Process.run('${standardJvm.path}/jre/bin/java.exe', [
        '--list-modules',
      ]);
      expect(java.exitCode, 0);
      for (final module in [
        'java.management',
        'jdk.crypto.ec',
        'jdk.charsets',
        'jdk.zipfs',
      ]) {
        expect(java.stdout, contains('$module@17.'));
      }
      expect(
        File('${standardJvm.path}/d2j/dex-tools-v2.4.jar').existsSync(),
        isTrue,
      );
      expect(
        File(
          '${support.path}/jvm/native/${ArmBridgeRuntime.version}/unidbg-android-0.9.9.jar',
        ).existsSync(),
        isTrue,
      );
      final pythonPath = '${support.path}/python/${PyRuntime.version}';
      final python = await Process.run('$pythonPath/python.exe', ['--version']);
      expect(python.exitCode, 0);
      expect(python.stdout, contains('Python ${PyRuntime.version}'));
      expect(Directory('$pythonPath/Lib/site-packages').existsSync(), isFalse);
      expect(Directory('${support.path}/mpv-yaozhi').existsSync(), isFalse);
      expect(
        Directory('${support.path}/jvm/${JvmRuntime.version}').existsSync(),
        isFalse,
      );
    },
    skip:
        !Platform.isWindows ||
        !File('${standard.path}/ready.json').existsSync(),
  );
}
