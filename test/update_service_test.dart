import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/core/app_version.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/services/update/update_service.dart';

Map<String, Object?> asset(
  String name, {
  String url = 'https://x/a.zip',
  int size = 1,
}) => {'name': name, 'browser_download_url': url, 'size': size};

void main() {
  const relayUrl = 'https://gh-proxy.com/${UpdateService.latestUrl}';

  test('GitHub 正常返回已安装版本时无需请求中转', () async {
    final service = UpdateService(
      http: AppHttp(
        client: MockClient((request) async {
          expect(request.url.toString(), UpdateService.latestUrl);
          return http.Response(jsonEncode({'tag_name': 'v$kAppVersion'}), 200);
        }),
      ),
      createRelayClient: () => throw TestFailure('不应创建中转客户端'),
    );

    expect(await service.check(), isNull);
  });

  test('GitHub 无最新发布时继续检查原仓库的标签', () async {
    final service = UpdateService(
      http: AppHttp(
        client: MockClient((request) async {
          return switch (request.url.pathSegments.last) {
            'latest' => http.Response('', 404),
            'releases' => http.Response('[]', 200),
            'tags' => http.Response('[{"name":"v99.0.0.1"}]', 200),
            _ => throw TestFailure('意外请求 ${request.url}'),
          };
        }),
      ),
      createRelayClient: () => throw TestFailure('不应创建中转客户端'),
    );

    expect((await service.check())?.version, '99.0.0.1');
  });

  test('代理连接失败时改走中转，更新链接只使用原仓库', () async {
    const downloadPrefix =
        'https://github.com/$kGithubRepo/releases/download/v99.0.0.1';
    const zip = 'MisaTV-windows-x64.zip';
    final service = UpdateService(
      http: AppHttp(
        client: MockClient((request) async {
          expect(request.url.toString(), UpdateService.latestUrl);
          throw const SocketException('代理连接失败');
        }),
      ),
      createRelayClient: () => MockClient((request) async {
        expect(request.url.toString(), relayUrl);
        expect(request.headers['User-Agent'], 'MisaTV-updater');
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response(
          jsonEncode({
            'tag_name': 'v99.0.0.1',
            'body': '发布说明',
            'html_url': 'https://example.com/fake-release',
            'assets': [
              asset('fake-windows.zip', url: 'https://example.com/fake.zip'),
              asset(
                'MisaTV-macos.zip',
                url: 'https://github.com/other/repo/releases/download/v99.0.0.1/MisaTV-macos.zip',
              ),
              asset(zip, url: '$downloadPrefix/$zip'),
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final release = await service.check();
    expect(release?.notes, '发布说明');
    expect(
      release?.htmlUrl,
      'https://github.com/$kGithubRepo/releases/tag/v99.0.0.1',
    );
    expect(release?.downloadUrl, '$downloadPrefix/$zip');
  });

  test('GitHub 和中转都未给出有效响应时报告检查失败', () async {
    final service = UpdateService(
      http: AppHttp(client: MockClient((_) async => http.Response('', 502))),
      createRelayClient: () => MockClient((request) async {
        expect(request.url.toString(), relayUrl);
        return http.Response('{"message":"API rate limit exceeded"}', 200);
      }),
    );

    await expectLater(service.check(), throwsA(isA<UpdateCheckException>()));
  });

  test('只选择匹配当前版本和包型的差异包', () {
    const tag = 'v99.0.0.1';
    const base = 'https://github.com/$kGithubRepo/releases/download/$tag';
    const full = 'MisaTV-delta-x64-full-v$kAppVersion-to-$tag.zip';
    const lite = 'MisaTV-delta-x64-lite-v$kAppVersion-to-$tag.zip';
    const standard = 'MisaTV-delta-x64-standard-v$kAppVersion-to-$tag.zip';
    final digest = 'sha256:${'a' * 64}';
    final release = UpdateService.parseGithubRelease({
      'tag_name': tag,
      'assets': [
        {...asset(full, url: 'https://example.com/$full'), 'digest': digest},
        {...asset(lite, url: '$base/$lite'), 'digest': 'missing'},
        {...asset(full, url: '$base/$full'), 'digest': digest},
        {...asset(standard, url: '$base/$standard'), 'digest': digest},
        asset('MisaTV-windows-x64-lite.zip'),
        asset('MisaTV-windows-x64.zip'),
      ],
    });
    expect(release.windowsDeltas.keys, ['full', 'standard']);
    expect(release.windowsDeltas['full']?.url, '$base/$full');
    expect(release.windowsDeltas['standard']?.url, '$base/$standard');
    expect(release.assetName, 'MisaTV-windows-x64.zip');
    expect(UpdateService.pickAsset([asset(full)]), isNull);
  });

  test('整包按包型记录，要求官方资产地址、大小和摘要', () {
    const tag = 'v99.0.0.1';
    const full = 'MisaTV-windows-x64.zip';
    const lite = 'MisaTV-windows-x64-lite.zip';
    const standard = 'MisaTV-windows-x64-standard.zip';
    const base = 'https://github.com/$kGithubRepo/releases/download/$tag';
    final digest = 'sha256:${'b' * 64}';
    final release = UpdateService.parseGithubRelease({
      'tag_name': tag,
      'assets': [
        {...asset(full, url: '$base/$full'), 'digest': digest},
        {...asset(lite, url: 'https://example.com/$lite'), 'digest': digest},
        {...asset(lite, url: '$base/$lite'), 'digest': digest, 'size': 0},
        asset(lite, url: '$base/$lite'),
        {...asset(lite, url: '$base/$lite'), 'digest': digest},
        {...asset(standard, url: '$base/$standard'), 'digest': digest},
      ],
    });
    expect(release.windowsPackages['full']?.name, full);
    expect(release.windowsPackages['lite']?.url, '$base/$lite');
    expect(release.windowsPackages['lite']?.digest, digest);
    expect(release.windowsPackages['standard']?.url, '$base/$standard');
    expect(release.windowsDeltas, isEmpty);
  });

  test('版本号归一：去掉 v 前缀与构建号', () {
    expect(UpdateService.normalizeVersion('v0.9.1'), '0.9.1');
    expect(UpdateService.normalizeVersion('  V1.2.3 '), '1.2.3');
    expect(UpdateService.normalizeVersion('1.2.3+45'), '1.2.3');
  });

  test('版本比较：按数字比，预测后缀更低', () {
    expect(UpdateService.compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(UpdateService.compareVersions('0.9.0', '0.9.0'), 0);
    expect(UpdateService.compareVersions('v0.9.0+10', '0.9.0'), 0);
    expect(UpdateService.compareVersions('0.9.1', '0.9.0'), greaterThan(0));
    expect(UpdateService.compareVersions('1.0.0-beta', '1.0.0'), lessThan(0));
    expect(UpdateService.compareVersions('1.2', '1.2.0'), 0);
  });

  // 这些用例针对「把版本拼成一个数字再比大小」的常见错误写法
  // （例如 patch + minor*1000 + major*1000000，见 Ghosten Player 的 toDouble）。
  // 那种写法在分段数值变大时会直接判错，这里逐条锁住。
  test('版本比较：分段数值不受进位影响', () {
    // patch 超过 1000：数字拼法会把 1.2.1000 与 1.2.3 算成同值或倒挂。
    expect(UpdateService.compareVersions('1.2.1000', '1.2.3'), greaterThan(0));
    expect(UpdateService.compareVersions('1.2.3', '1.2.1000'), lessThan(0));
    // minor 超过 1000 同理。
    expect(
      UpdateService.compareVersions('1.1000.0', '1.3.999'),
      greaterThan(0),
    );
    // 正常进位：0.10.0 > 0.9.9（字符串比较会判错，这里必须走数值）。
    expect(UpdateService.compareVersions('0.10.0', '0.9.10'), greaterThan(0));
  });

  test('版本比较：多段 / 少段 / 脏数据都稳定', () {
    expect(UpdateService.compareVersions('1.2.3.4', '1.2.3'), greaterThan(0));
    expect(UpdateService.isNewer('v1.2.0.10', '1.2.0.9'), isTrue);
    expect(UpdateService.isNewer('v1.3.0.1', '1.2.0.10'), isTrue);
    expect(UpdateService.compareVersions('1', '1.0.0'), 0);
    // 非数字段按 0 处理，不抛异常。
    expect(
      () => UpdateService.compareVersions('abc', '1.0.0'),
      returnsNormally,
    );
    expect(UpdateService.compareVersions('', '0.0.0'), 0);
  });

  test('版本比较：预发布标记', () {
    expect(
      UpdateService.compareVersions('1.0.0-alpha', '1.0.0-beta'),
      lessThan(0),
    );
    expect(
      UpdateService.compareVersions('1.0.0-beta.2', '1.0.0-beta.1'),
      greaterThan(0),
    );
    expect(
      UpdateService.compareVersions('1.0.0', '1.0.0-beta'),
      greaterThan(0),
    );
  });

  test('构建号不参与比较（产品决策：只改 +N 不发更新提示）', () {
    // 这条锁住有意为之的语义：pubspec 的 `1.0.0+11` → `+12` 不应触发提示。
    expect(UpdateService.isNewer('1.0.0+12', '1.0.0+11'), isFalse);
    expect(UpdateService.isNewer('1.0.1+1', '1.0.0+99'), isTrue);
  });

  test('是否比本地新', () {
    expect(UpdateService.isNewer('0.9.1', '0.9.0'), isTrue);
    expect(UpdateService.isNewer('0.9.0', '0.9.0'), isFalse);
    expect(UpdateService.isNewer('0.8.9', '0.9.0'), isFalse);
  });

  test('解析 release JSON：tag / 说明 / 资产', () {
    final release = UpdateService.parseGithubRelease({
      'tag_name': 'v0.9.1',
      'body': '### 更新内容\n- 修好封面',
      'html_url': 'https://github.com/yagami-hue/MisaTV/releases/tag/v0.9.1',
      'published_at': '2026-11-11T10:00:00Z',
      'assets': [
        asset('MisaTV-0.9.1-linux.zip'),
        asset('MisaTV-0.9.1-windows-x64.zip'),
      ],
    });
    expect(release.version, '0.9.1');
    expect(release.notes, contains('修好封面'));
    expect(release.assetName, 'MisaTV-0.9.1-windows-x64.zip');
    expect(release.openUrl, 'https://x/a.zip');
  });

  test('没有资产时用 release 页面兜底', () {
    final release = UpdateService.parseGithubRelease({
      'tag_name': '0.9.2',
      'html_url': 'https://github.com/yagami-hue/MisaTV/releases/tag/0.9.2',
      'assets': const [],
    });
    expect(release.assetName, isEmpty);
    expect(release.openUrl, contains('/releases/tag/0.9.2'));
  });

  test('挑资产：Windows zip 优先，其次任意 zip / exe', () {
    expect(
      UpdateService.pickAsset([
        asset('MisaTV.apk'),
        asset('MisaTV-0.9.1-linux.zip'),
        asset('MisaTV-0.9.1-windows-x64.zip'),
      ])?.name,
      'MisaTV-0.9.1-windows-x64.zip',
    );
    expect(
      UpdateService.pickAsset([asset('a.dmg'), asset('b.zip')])?.name,
      'b.zip',
    );
    expect(UpdateService.pickAsset([asset('setup.exe')])?.name, 'setup.exe');
    expect(UpdateService.pickAsset(const []), isNull);
  });

  test('应用版本的前三段对应 pubspec 中的官方版本', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    const official = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)';
    final match = RegExp(
      '^version:[ \\t]*($official)\\+[1-9][0-9]*[ \\t\\r]*\$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(
      kAppVersion,
      matches('^${RegExp.escape(match!.group(1)!)}\\.[1-9][0-9]*\$'),
    );
  });
}
