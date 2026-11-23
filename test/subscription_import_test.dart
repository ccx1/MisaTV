import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/app.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/services/cms_source.dart';
import 'package:kniephos/services/config_parser.dart';
import 'package:kniephos/services/jar_spider_service.dart';
import 'package:kniephos/services/js_spider_service.dart';
import 'package:kniephos/services/live_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/py_spider_service.dart';
import 'package:kniephos/services/search_service.dart';
import 'package:kniephos/services/source_service.dart';
import 'package:kniephos/state/app_state.dart';
import 'package:kniephos/ui/widgets/import_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SubscriptionHttp extends AppHttp {
  final responses = <String, String>{};
  final requests = <String>[];
  final delays = <String, Duration>{};
  var pending = 0;
  var maxPending = 0;

  @override
  Future<HttpResponseText> getText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    bool useDoh = false,
  }) async {
    requests.add(url);
    pending++;
    if (pending > maxPending) maxPending = pending;
    try {
      await Future<void>.delayed(delays[url] ?? Duration.zero);
      final body = responses[url];
      if (body == null) throw AppHttpException('HTTP 404');
      return HttpResponseText(url, body, 200, 'application/json');
    } finally {
      pending--;
    }
  }

  @override
  Future<HttpResponseText?> probeText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 32 << 10,
    bool useDoh = false,
  }) => getText(url);
}

// Cache housekeeping is unrelated to importing; keep tests off the real disk.
class _TestJar extends JarSpiderService {
  _TestJar(AppHttp http) : super(driveTokens: () => {}, http: http);

  @override
  Future<void> purgeJarCaches(Set<String> keepKeys) async {}
}

Future<AppState> _app(AppHttp http) async {
  final source = SourceService(
    CmsSource(http),
    JsSpiderService(driveTokens: () => {}, localSeed: () => {}),
    PySpiderService(driveTokens: () => {}),
    _TestJar(http),
  );
  return AppState(
    store: await LocalStore.create(),
    http: http,
    sourceService: source,
    searchService: SearchService(source),
    liveService: LiveService(http, source),
    driveTokens: {},
  );
}

String _site(String name, {String jar = ''}) => jsonEncode({
  'spider': './$name.jar',
  'sites': [
    {'key': 'same', 'name': name, 'type': 3, 'api': 'csp_$name', 'jar': jar},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = 'https://example.test/TVBox/GYCK.json';
  late _SubscriptionHttp http;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    http = _SubscriptionHttp();
    app = await _app(http);
    app.jarReady = true;
  });

  tearDown(() {
    http.close();
    app.dispose();
  });

  test('多仓默认预览可展开，取消不落盘，确认复用快照且保留各仓 JAR', () async {
    http.responses[root] = jsonEncode({
      'urls': [
        {'name': 'A', 'url': './a.json'},
        {'name': '失效线路', 'url': './gone.json'},
        {'name': 'B', 'url': './b.json'},
        {'name': '空线路', 'url': './empty.json'},
      ],
    });
    http.responses['https://example.test/TVBox/a.json'] = _site('A');
    http.responses['https://example.test/TVBox/b.json'] = _site('B');
    http.responses['https://example.test/TVBox/empty.json'] = '{"sites":[]}';
    http.delays['https://example.test/TVBox/a.json'] = const Duration(
      milliseconds: 10,
    );

    final preview = await app.previewImportFromUrl(root, name: '光影仓库');
    expect(preview.siteCount, 2);
    expect(preview.mergedCount, 2);
    expect(preview.added, 2);
    expect(preview.warnings, hasLength(2));
    expect(app.profiles, isEmpty);
    expect(app.store.loadProfiles(), isEmpty);
    final parsed = ConfigParser.parse(preview.text, jarReady: true);
    expect(parsed.config.sites.map((s) => s.name), ['A', 'B (1)']);
    expect(parsed.config.sites.map((s) => s.jar), [
      'https://example.test/TVBox/A.jar',
      'https://example.test/TVBox/B.jar',
    ]);

    // Remote contents can change after preview. Confirm exactly what was shown.
    final requestCount = http.requests.length;
    http.responses.clear();
    final outcome = await app.commitImportPreview(preview);
    expect(http.requests.length, requestCount);
    expect(outcome.profile.siteCount, preview.siteCount);
    expect(outcome.profile.rawJson, preview.text);
    expect(outcome.profile.url, root);
    expect(outcome.mergedCount, preview.mergedCount);
    expect(outcome.warnings, preview.warnings);
    expect(app.store.loadProfiles().single.rawJson, preview.text);
  });

  test('直接导入和刷新都展开多仓，显式 JAR 优先且按原顺序合并', () async {
    http.responses[root] = '{"urls":["./a.json","./b.json"]}';
    http.responses['https://example.test/TVBox/a.json'] = _site('A');
    http.responses['https://example.test/TVBox/b.json'] = _site(
      'B',
      jar: 'https://cdn.test/override.jar',
    );
    final imported = await app.importFromUrl(root);
    expect(imported.mergedCount, 2);
    expect(app.config!.sites.last.jar, 'https://cdn.test/override.jar');
    http.responses['https://example.test/TVBox/b.json'] = _site('C');
    final refreshed = await app.refreshProfile(imported.profile.id);
    expect(refreshed.profile.id, imported.profile.id);
    expect(refreshed.mergedCount, 2);
    expect(app.config!.sites.last.jar, 'https://example.test/TVBox/C.jar');
    expect(app.profiles, hasLength(1));
  });

  test('全部失效或为空时不写入，不覆盖已有订阅', () async {
    final imported = await app.importFromJson(_site('Original'));
    http.responses[root] = '{"urls":[{"name":"空仓","url":"./empty.json"}]}';
    http.responses['https://example.test/TVBox/empty.json'] = '{"sites":[]}';
    await expectLater(
      app.previewImportFromUrl(root),
      throwsA(
        isA<AppException>().having((e) => e.message, 'message', contains('空仓')),
      ),
    );
    expect(app.profiles.single.rawJson, imported.profile.rawJson);
  });

  test('普通订阅仍能预览和确认', () async {
    final preview = await app.previewImportText(_site('A'));
    expect(preview.mergedCount, 0);
    final imported = await app.commitImportPreview(preview);
    expect(imported.profile.siteCount, 1);
    expect(imported.mergedCount, 0);
  });

  test('多仓并发有界且保持所有有效线路', () async {
    final urls = [for (var i = 0; i < 9; i++) 'https://example.test/$i.json'];
    for (final url in urls) {
      http.responses[url] = _site('A');
      http.delays[url] = const Duration(milliseconds: 5);
    }
    final preview = await app.previewImportText(jsonEncode({'urls': urls}));
    expect(preview.siteCount, 9);
    expect(preview.mergedCount, 9);
    expect(http.maxPending, inInclusiveRange(2, 4));
  });

  testWidgets('默认勾选预览时可从导入窗口确认多仓订阅', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    http.responses[root] = '{"urls":["./a.json"]}';
    http.responses['https://example.test/TVBox/a.json'] = _site('A');
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showImportConfigSheet(context),
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    final urlField = find.byWidgetPredicate(
      (w) => w is TextField && w.keyboardType == TextInputType.url,
    );
    await tester.enterText(urlField, root);
    await tester.tap(find.text('开始导入'));
    // The sheet keeps its loading spinner behind the confirmation dialog.
    for (var i = 0; i < 20 && find.text('导入预览').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('导入预览'), findsOneWidget);
    expect(find.text('已合并 1 条线路'), findsOneWidget);
    expect(app.profiles, isEmpty);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(find.text('导入预览'), findsNothing);
    expect(app.profiles.single.siteCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
