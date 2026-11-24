import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/local_relay.dart';

Future<void> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory root;
  late HttpServer upstream;
  final relay = LocalRelay.instance;
  var enabled = true;
  var episodeBufferEnabled = false;
  var hits = 0;
  final ranges = <String?>[];
  const total = 32 * 1024 * 1024;
  Completer<void>? continueSlow;
  var allowDuplicateRange = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('misatv-cache-relay-');
    enabled = true;
    episodeBufferEnabled = false;
    hits = 0;
    ranges.clear();
    continueSlow = null;
    allowDuplicateRange = false;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      hits++;
      final response = request.response;
      final range = request.headers.value('range');
      ranges.add(range);
      try {
        response.headers.contentType = ContentType('video', 'mp4');
        if (request.uri.path == '/vod.m3u8' ||
            request.uri.path == '/live.m3u8') {
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          response.write('#EXTM3U\n#EXTINF:4,\nsegment.ts\n');
          if (request.uri.path == '/vod.m3u8') {
            response.write('#EXTINF:6,\nsegment2.ts\n#EXT-X-ENDLIST\n');
          }
        } else if (request.uri.path == '/small.mp4' ||
            request.uri.path == '/next.mp4') {
          const length = 1024;
          response.statusCode = 206;
          response.headers.set(
            'content-range',
            'bytes 0-${length - 1}/$length',
          );
          response.contentLength = length;
          response.add(List.filled(length, 1));
        } else if (request.uri.path == '/segment.ts' ||
            request.uri.path == '/segment2.ts') {
          response.contentLength = 32;
          response.add(List.generate(32, (i) => i));
        } else if (request.uri.path == '/bad.mp4') {
          response.statusCode = 206;
          response.headers.set('content-range', 'bytes 0-20/10');
          response.contentLength = 4;
          response.add([1, 2, 3, 4]);
        } else if (request.uri.path == '/slow.mp4') {
          response.statusCode = 206;
          final size = allowDuplicateRange ? 131072 : 262144;
          response.headers.set('content-range', 'bytes 0-131071/$size');
          response.contentLength = 131072;
          response.bufferOutput = false;
          response.add(List.filled(65536, 1));
          await response.flush();
          if (!allowDuplicateRange || hits == 1) {
            await continueSlow!.future;
          }
          response.add(List.filled(65536, 2));
        } else {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
          final start = match == null ? 0 : int.parse(match[1]!);
          final end =
              (match == null ? 1023 : int.tryParse(match[2]!) ?? total - 1)
                  .clamp(0, total - 1);
          response.statusCode = match == null ? 200 : 206;
          if (match != null) {
            response.headers.set('content-range', 'bytes $start-$end/$total');
          }
          response.contentLength = end - start + 1;
          for (var offset = start; offset <= end; offset += 65536) {
            final length = (end - offset + 1).clamp(0, 65536);
            response.add(List.generate(length, (i) => (offset + i) % 251));
          }
        }
        await response.close();
      } catch (_) {
        // 切集测试会主动取消上游。
      }
    });
    await relay.start(
      fileRoot: root.path,
      driveTokens: () => {},
      rules: () => [],
      purifyEnabled: () => false,
      cacheDir: () => '${root.path}/cache',
      cacheEnabled: () => enabled,
      cacheLimitMb: () => 16,
      episodeBufferEnabled: () => episodeBufferEnabled,
    );
  });

  tearDown(() async {
    if (continueSlow != null && !continueSlow!.isCompleted) {
      continueSlow!.complete();
    }
    relay.releasePlaySessions();
    await waitUntil(() => relay.activePlaySessions == 0);
    await waitUntil(
      () =>
          !Directory('${root.path}/cache').existsSync() ||
          !Directory('${root.path}/cache')
              .listSync(recursive: true)
              .whereType<File>()
              .any((f) => f.path.endsWith('.tmp')),
    );
    await relay.stop();
    await upstream.close(force: true);
    await root.delete(recursive: true);
  });

  String play(String path) =>
      relay.playUrl('http://127.0.0.1:${upstream.port}/$path');

  Future<({int status, String? range, List<int> bytes})> fetch(
    String path, {
    String? range,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(play(path)));
      if (range != null) request.headers.set('range', range);
      final response = await request.close();
      return (
        status: response.statusCode,
        range: response.headers.value('content-range'),
        bytes: await response.expand((b) => b).toList(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> waitForCache() => waitUntil(
    () =>
        Directory('${root.path}/cache').existsSync() &&
        Directory('${root.path}/cache')
            .listSync(recursive: true)
            .whereType<File>()
            .any((f) => f.path.endsWith('.json')),
  );

  PlaybackPrefetch startPrefetch({
    bool Function()? isPlaying,
    bool Function()? isBuffering,
  }) => relay.startPlaybackPrefetch(
    isPlaying: isPlaying ?? () => true,
    isBuffering: isBuffering ?? () => false,
  )!;

  test('MP4 Range 落盘后，重播和区间内回拖不再访问上游', () async {
    final first = await fetch('movie.mp4', range: 'bytes=100-199');
    expect(first.status, 206);
    expect(first.range, 'bytes 100-199/$total');
    await waitForCache();
    final replay = await fetch('movie.mp4', range: 'bytes=100-199');
    final seek = await fetch('movie.mp4', range: 'bytes=120-139');
    expect(replay.bytes, first.bytes);
    expect(seek.bytes, List.generate(20, (i) => (120 + i) % 251));
    expect(seek.range, 'bytes 120-139/$total');
    expect(hits, 1);
    await fetch('movie.mp4', range: 'bytes=90-109');
    expect(hits, 2, reason: '未缓存的空洞必须回源');
  });

  test('MKV 开放 Range 每次最多拉取 8MB，关闭缓存恢复原样透传', () async {
    final first = await fetch('movie.mkv', range: 'bytes=0-');
    expect(ranges.single, 'bytes=0-8388607');
    expect(first.bytes.length, 8 * 1024 * 1024);
    enabled = false;
    await fetch('movie.mkv', range: 'bytes=10-19');
    expect(ranges.last, 'bytes=10-19');
    expect(hits, 2);
  });

  test('HLS 整段缓存继续可用，清空后重新回源', () async {
    final first = await fetch('segment.ts');
    await waitForCache();
    expect((await fetch('segment.ts')).bytes, first.bytes);
    expect(hits, 1);
    await relay.clearStreamCache();
    await fetch('segment.ts');
    expect(hits, 2);
  });

  test('非法 Content-Range 透传但不缓存', () async {
    await fetch('bad.mp4', range: 'bytes=0-3');
    await fetch('bad.mp4', range: 'bytes=0-3');
    expect(hits, 2);
    expect(await relay.streamCacheBytes(), 0);
  });

  test('按集预取后，当前集与后续集的首个 Range 都能直接读盘', () async {
    episodeBufferEnabled = true;
    final task = startPrefetch();
    expect(await task.episode(play('small.mp4')), isTrue);
    expect(await task.episode(play('next.mp4')), isTrue);
    task.cancel();
    expect(
      (await fetch('small.mp4', range: 'bytes=0-')).bytes,
      hasLength(1024),
    );
    expect((await fetch('next.mp4', range: 'bytes=0-')).bytes, hasLength(1024));
    expect(hits, 2);
  });

  test('按集预取只缓存有限 HLS，分片可被播放器复用', () async {
    final task = startPrefetch();
    expect(await task.episode(play('live.m3u8')), isFalse);
    expect(hits, 1);
    final progress = <double>[];
    expect(
      await task.episode(play('vod.m3u8'), onProgress: progress.add),
      isTrue,
    );
    expect(progress, [0.4, 1.0]);
    expect(hits, 4);
    expect((await fetch('segment.ts')).bytes, hasLength(32));
    expect(hits, 4);
  });

  test('缓存满时只保留已预取区间，前台仍能读取首段和未缓存数据', () async {
    episodeBufferEnabled = true;
    final task = startPrefetch();
    final progress = <double>[];
    expect(
      await task.episode(play('movie.mp4'), onProgress: progress.add),
      isFalse,
    );
    expect(progress, [0.25, 0.5]);
    expect(ranges, [
      'bytes=0-8388607',
      'bytes=8388608-16777215',
      'bytes=16777216-25165823',
    ]);
    expect(await relay.streamCacheBytes(), 16 * 1024 * 1024);
    final start = await fetch('movie.mp4', range: 'bytes=100-');
    expect(start.range, 'bytes 100-8388607/$total');
    expect(hits, 3);
    final outside = await fetch('movie.mp4', range: 'bytes=25165824-25165825');
    expect(outside.bytes, hasLength(2));
    expect(hits, 4);
    expect(await relay.streamCacheBytes(), 16 * 1024 * 1024);
  });

  test('播放未就绪时等待，切集取消预取中的响应和临时文件', () async {
    continueSlow = Completer<void>();
    var ready = false;
    final task = startPrefetch(isBuffering: () => !ready);
    final result = task.episode(play('slow.mp4'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hits, 0);
    ready = true;
    await waitUntil(() => hits == 1);
    task.cancel();
    expect(await result.timeout(const Duration(seconds: 5)), isFalse);
    expect(await relay.streamCacheBytes(), 0);
  });

  test('暂停播放后，前台连接占着同一区间时仍能完整预取', () async {
    continueSlow = Completer<void>();
    allowDuplicateRange = true;
    final foreground = fetch('slow.mp4', range: 'bytes=0-131071');
    var playing = true;
    final task = startPrefetch(
      isPlaying: () => playing,
      isBuffering: () => true,
    );
    try {
      await waitUntil(() => relay.activePlaySessions == 1);
      final progress = <double>[];
      final result = task.episode(play('slow.mp4'), onProgress: progress.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hits, 1);
      playing = false;
      expect(await result.timeout(const Duration(seconds: 5)), isTrue);
      expect(relay.activePlaySessions, 1, reason: '前台连接仍然打开');
      expect(progress, [1.0]);
      expect(await relay.streamCacheBytes(), 131072);
    } finally {
      task.cancel();
      continueSlow!.complete();
      await foreground;
    }
  });

  test('缓存开启时切集可取消旧会话，不保留半截文件', () async {
    continueSlow = Completer<void>();
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(play('slow.mp4')));
      request.headers.set('range', 'bytes=0-131071');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final received = Completer<void>();
      final subscription = response.listen((_) {
        if (!received.isCompleted) received.complete();
      }, onError: (Object _) {});
      await received.future.timeout(const Duration(seconds: 5));
      expect(relay.releasePlaySessions(), 1);
      await waitUntil(() => relay.activePlaySessions == 0);
      await subscription.cancel();
      expect(await relay.streamCacheBytes(), 0);
      await waitUntil(
        () =>
            !Directory('${root.path}/cache')
                .listSync(recursive: true)
                .whereType<File>()
                .any((f) => f.path.endsWith('.tmp')),
      );
    } finally {
      client.close(force: true);
    }
  });
}
