import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/app.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/services/cms_source.dart';
import 'package:kniephos/services/jar_spider_service.dart';
import 'package:kniephos/services/js_spider_service.dart';
import 'package:kniephos/services/live_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/py_spider_service.dart';
import 'package:kniephos/services/runtime_extension.dart';
import 'package:kniephos/services/search_service.dart';
import 'package:kniephos/services/source_service.dart';
import 'package:kniephos/state/app_state.dart';
import 'package:kniephos/ui/widgets/source_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _PickerApp extends AppState {
  _PickerApp(LocalStore store, AppHttp http, SourceService source)
    : super(
        store: store,
        http: http,
        sourceService: source,
        searchService: SearchService(source),
        liveService: LiveService(http, source),
        driveTokens: {},
      );

  bool runtimeReady = false;
  int checks = 0;

  @override
  SiteConfig get config => const SiteConfig(
    sites: [
      SourceBean(key: 'cms', name: '普通站点', type: 1, api: 'https://cms.test'),
      SourceBean(key: 'jar', name: 'JAR 站点', type: 3, api: 'csp_Test'),
    ],
  );

  @override
  Future<void> refreshJarReady() async {
    checks++;
    jarReady = runtimeReady;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _PickerApp app;
  late AppHttp http;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('misatv-picker-runtime-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    http = AppHttp();
    final source = SourceService(
      CmsSource(http),
      JsSpiderService(driveTokens: () => {}, localSeed: () => {}),
      PySpiderService(driveTokens: () => {}),
      JarSpiderService(driveTokens: () => {}, http: http),
    );
    app = _PickerApp(await LocalStore.create(), http, source);
    app.activeSiteKey = 'cms';
  });

  tearDown(() {
    RuntimeInstallPrompt.instance.hostContext = null;
    RuntimeInstallPrompt.instance.onReveal = null;
    app.dispose();
    http.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                RuntimeInstallPrompt.instance.hostContext = context;
                return TextButton(
                  onPressed: () => showSourcePicker(context),
                  child: const Text('选择'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
  }

  testWidgets('缺少 JVM 的站点可点击进入安装，取消保留原站点', (tester) async {
    await open(tester);
    expect(find.text('需要 JVM 运行时，点击下载安装'), findsOneWidget);
    await tester.tap(find.text('JAR 站点'));
    await tester.pumpAndSettle();
    expect(find.text('需要下载JVM 运行时'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.activeSiteKey, 'cms');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('打开选站时重新检测，已安装站点立即恢复可选', (tester) async {
    app.runtimeReady = true;
    expect(app.jarReady, isFalse);
    await open(tester);
    expect(app.checks, 1);
    expect(find.text('需要 JVM 运行时，点击下载安装'), findsNothing);
    await tester.tap(find.text('JAR 站点'));
    await tester.pumpAndSettle();
    expect(app.activeSiteKey, 'jar');
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('确认下载进入已有安装流程，并保留用户选择的站点', (tester) async {
    RuntimeExtension? requested;
    RuntimeInstallPrompt.instance.onReveal = (kind) async {
      requested = kind;
      app.runtimeReady = true;
      await app.refreshJarReady();
    };
    await open(tester);
    await tester.tap(find.text('JAR 站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(requested, RuntimeExtension.jvm);
    expect(app.jarReady, isTrue);
    expect(app.activeSiteKey, 'jar');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
