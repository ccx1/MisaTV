import 'dart:async';
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
  final gates = <String, Completer<void>>{};
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
      await gates[url]?.future;
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
    bool skipBinaryMedia = false,
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
    final progress = <(int, int)>[];
    final preview = await app.previewImportText(
      jsonEncode({'urls': urls}),
      task: SubscriptionImportTask(
        onProgress: (completed, total) => progress.add((completed, total)),
      ),
    );
    expect(progress, [for (var i = 0; i <= 9; i++) (i, 9)]);
    expect(preview.siteCount, 9);
    expect(preview.mergedCount, 9);
    expect(http.maxPending, inInclusiveRange(2, 4));
  });

  test('取消直接导入会停止派发子订阅，也不会保存部分结果', () async {
    final urls = [for (var i = 0; i < 9; i++) 'https://example.test/$i.json'];
    for (final url in urls) {
      http.responses[url] = _site('A');
      http.delays[url] = const Duration(milliseconds: 5);
    }
    late final SubscriptionImportTask task;
    task = SubscriptionImportTask(
      onProgress: (completed, _) {
        if (completed == 1) task.cancel();
      },
      onSaving: () => fail('已取消的导入开始保存'),
    );

    await expectLater(
      app.importFromJson(jsonEncode({'urls': urls}), task: task),
      throwsA(predicate((error) => error.toString() == '已取消导入')),
    );
    expect(http.requests, urls.take(4));
    expect(app.profiles, isEmpty);
    expect(app.store.loadProfiles(), isEmpty);
  });

  test('首条成功后即可使用，后台合入保留选源和删除记录', () async {
    const slowUrl = 'https://example.test/TVBox/slow.json';
    const fastUrl = 'https://example.test/TVBox/fast.json';
    http.responses[root] = '{"urls":["./slow.json","./fast.json"]}';
    http.responses[slowUrl] = _site('Slow');
    http.responses[fastUrl] = jsonEncode({
      'sites': [
        {
          'key': 'same',
          'name': 'Fast',
          'type': 1,
          'api': 'https://fast.test/api',
        },
        {
          'key': 'keep',
          'name': 'Keep',
          'type': 1,
          'api': 'https://keep.test/api',
        },
      ],
    });
    final slow = http.gates[slowUrl] = Completer<void>();
    addTearDown(() {
      if (!slow.isCompleted) slow.complete();
    });

    final preview = await app
        .previewImportFromUrl(
          root,
          task: SubscriptionImportTask(allowBackground: true),
        )
        .timeout(const Duration(seconds: 5));
    expect(preview.siteCount, 2);
    expect(preview.remainingSubscriptions, 1);
    expect(app.store.loadProfiles(), isEmpty);
    final imported = await app.commitImportPreview(preview);
    expect(imported.profile.siteCount, 2);
    expect(http.pending, 1);
    final firstKey = app.config!.sites.first.key;
    final keepKey = app.config!.sites.last.key;
    await app.setActiveSite(keepKey);
    expect(await app.removeSite(firstKey), isTrue);

    final merged = Completer<void>();
    void onChange() {
      if (app.config?.sites.any((site) => site.name == 'Slow') == true &&
          !merged.isCompleted) {
        merged.complete();
      }
    }

    app.addListener(onChange);
    slow.complete();
    try {
      await merged.future.timeout(const Duration(seconds: 5));
    } finally {
      app.removeListener(onChange);
    }
    expect(app.activeSiteKey, keepKey);
    expect(app.activeProfile!.id, imported.profile.id);
    expect(app.config!.sites.map((site) => site.name), ['Slow', 'Keep']);
    expect(app.activeProfile!.deletedSiteKeys, contains(firstKey));
    expect(app.profileHistory, isEmpty);
    final slowKey = app.config!.sites.first.key;

    final refreshed = await app.refreshProfile(imported.profile.id);
    expect(refreshed.profile.id, imported.profile.id);
    expect(
      app.config!.sites.map((site) => site.key),
      unorderedEquals([keepKey, slowKey]),
    );
    expect(app.activeSiteKey, keepKey);
  });

  test('删除已有首批内容的档案会停止后台合入', () async {
    const slowUrl = 'https://example.test/TVBox/slow.json';
    const fastUrl = 'https://example.test/TVBox/fast.json';
    http.responses[root] = '{"urls":["./slow.json","./fast.json"]}';
    http.responses[slowUrl] = _site('Slow');
    http.responses[fastUrl] = _site('Fast');
    final slow = http.gates[slowUrl] = Completer<void>();
    addTearDown(() {
      if (!slow.isCompleted) slow.complete();
    });

    final task = SubscriptionImportTask(allowBackground: true);
    final imported = await app
        .importFromUrl(root, task: task)
        .timeout(const Duration(seconds: 5));
    expect(imported.profile.siteCount, 1);
    await app.removeProfile(imported.profile.id);
    expect(task.isCancelled, isTrue);
    slow.complete();
    await Future<void>.delayed(Duration.zero);
    expect(app.profiles, isEmpty);
    expect(app.store.loadProfiles(), isEmpty);
  });

  test('大配置可确认、重读和切换，并按调用顺序保存', () async {
    final config = jsonEncode({
      'urls': ['https://example.test/large.json'],
    });
    http.responses['https://example.test/large.json'] = jsonEncode({
      'sites': [
        for (var i = 0; i < 1200; i++)
          {
            'key': 'large-$i',
            'name': 'Large site $i',
            'type': 1,
            'api': 'https://example.test/api/$i',
          },
      ],
    });
    final preview = await app.previewImportText(config);
    expect(preview.text.length, greaterThan(65536));
    final outcome = await app.commitImportPreview(preview);
    expect(outcome.profile.siteCount, 1200);

    final store = app.store;
    final pendingSave = store.saveProfiles([outcome.profile]);
    final pendingClear = store.saveProfiles([]);
    await Future.wait([pendingSave, pendingClear]);
    expect(await store.loadProfilesAsync(), isEmpty);

    final smaller = await app.importFromJson(_site('Other'));
    await app.activateProfile(outcome.profile.id);
    expect(app.config?.sites.length, 1200);
    await app.activateProfile(smaller.profile.id);
    expect(app.config?.sites.length, 1);
    expect((await store.loadProfilesAsync()).length, 2);
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
