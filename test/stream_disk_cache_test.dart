import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/stream_cache_io.dart';

void main() {
  late Directory root;
  late StreamDiskCache cache;
  var enabled = true;
  var limitMb = 1;
  final key = StreamDiskCache.keyOf('https://video.test/movie.mkv?sign=one');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('misatv-stream-cache-');
    enabled = true;
    limitMb = 1;
    cache = StreamDiskCache(
      dir: root.path,
      enabled: () => enabled,
      limitMb: () => limitMb,
    );
    await cache.totalBytes();
  });

  tearDown(() async {
    await cache.clear();
    await root.delete(recursive: true);
  });

  Future<void> put(
    String entryKey,
    List<int> bytes, {
    StreamCacheRange? range,
  }) async {
    final writer = await cache.open(
      entryKey,
      contentType: 'video/mp4',
      length: bytes.length,
      range: range,
    );
    expect(writer, isNotNull);
    writer!.add(bytes);
    await writer.commit();
  }

  test('缓存区间内的回拖和尾部 Range 直接读取正确字节', () async {
    await put(key, [10, 11, 12, 13], range: const StreamCacheRange(6, 9, 10));
    final hit = await cache.lookupRange(key, 'bytes=7-8');
    expect(hit!.contentRange, 'bytes 7-8/10');
    expect(
      await hit.file
          .openRead(hit.offset, hit.offset + hit.length)
          .expand((b) => b)
          .toList(),
      [11, 12],
    );
    final suffix = await cache.lookupRange(key, 'bytes=-2');
    expect(suffix!.contentRange, 'bytes 8-9/10');
    expect(await cache.lookupRange(key, 'bytes=5-8'), isNull);
    expect(await cache.lookupRange(key, 'bytes=10-'), isNull);
    expect(await cache.lookupRange(key, 'bytes=9-8'), isNull);
    expect(await cache.lookupRange(key, 'bytes=6-7,8-9'), isNull);
  });

  test('重启后仍能发现落盘区间，签名变化不会误用旧缓存', () async {
    await put(key, [1, 2, 3], range: const StreamCacheRange(0, 2, 100));
    final reopened = StreamDiskCache(
      dir: root.path,
      enabled: () => true,
      limitMb: () => 1,
    );
    expect((await reopened.lookupRange(key, 'bytes=0-2'))!.length, 3);
    final other = StreamDiskCache.keyOf(
      'https://video.test/movie.mkv?sign=two',
    );
    expect(await reopened.lookupRange(other, 'bytes=0-2'), isNull);
  });

  test('另一窗口写入后统计同步，扫描不会删除正在写入的临时文件', () async {
    final other = StreamDiskCache(
      dir: root.path,
      enabled: () => true,
      limitMb: () => 1,
    );
    expect(await other.totalBytes(), 0);
    final writer = await cache.open(key, contentType: 'video/mp4', length: 3);
    writer!.add([1, 2, 3]);
    await other.totalBytes();
    await writer.commit();
    expect(await other.totalBytes(), 3);
    expect(await other.entryCount(), 1);
  });

  test('完整 HLS 分片也可以响应 Range，越界不会伪造内容', () async {
    await put(key, [1, 2, 3, 4]);
    expect(
      (await cache.lookupRange(key, 'bytes=1-99'))!.contentRange,
      'bytes 1-3/4',
    );
    expect(await cache.lookupRange(key, 'bytes=4-'), isNull);
  });

  test('截断的响应和错误的 Content-Range 不会成为可读缓存', () async {
    final writer = await cache.open(key, contentType: 'video/mp4', length: 4);
    writer!.add([1, 2]);
    await writer.commit();
    expect(await cache.lookup(key), isNull);
    expect(await cache.totalBytes(), 0);
    expect(
      await cache.open(
        key,
        contentType: 'video/mp4',
        length: 4,
        range: const StreamCacheRange(0, 2, 9),
      ),
      isNull,
    );
  });

  test('同一分片并发写入不互相截断，中断后可重新缓存', () async {
    final first = await cache.open(key, contentType: 'video/mp4', length: 4);
    expect(await cache.open(key, contentType: 'video/mp4', length: 4), isNull);
    first!.add([1]);
    await first.abort();
    await put(key, [4, 3, 2, 1]);
    expect(await (await cache.lookup(key))!.file.readAsBytes(), [4, 3, 2, 1]);
  });

  test('清空期间正在写入的分片不能重新出现，downloads 保留', () async {
    final download = File('${root.path}/downloads/saved.mp4');
    await download.parent.create();
    await download.writeAsBytes([9]);
    final writer = await cache.open(key, contentType: 'video/mp4', length: 2);
    writer!.add([1, 2]);
    await cache.clear();
    await writer.commit();
    expect(await cache.lookup(key), isNull);
    expect(await download.readAsBytes(), [9]);
    expect(await cache.totalBytes(), 0);
  });

  test('容量超限淘汰旧区间，关闭开关后不读写', () async {
    final data = List<int>.filled(600 * 1024, 1);
    await put(
      key,
      data,
      range: StreamCacheRange(0, data.length - 1, data.length * 2),
    );
    final next = StreamDiskCache.keyOf('https://video.test/next');
    await put(next, data);
    expect(await cache.lookupRange(key, 'bytes=0-9'), isNull);
    expect(await cache.totalBytes(), lessThanOrEqualTo(1024 * 1024));
    enabled = false;
    expect(await cache.lookup(next), isNull);
    expect(await cache.open(key, contentType: 'video/mp4', length: 1), isNull);
  });

  test('开放 Range 限定为 8MB，多区间和后缀原样交给上游', () {
    expect(StreamDiskCache.limitRange('bytes=0-'), 'bytes=0-8388607');
    expect(StreamDiskCache.limitRange('bytes=8-15'), 'bytes=8-15');
    expect(StreamDiskCache.limitRange('bytes=-16'), 'bytes=-16');
    expect(StreamDiskCache.limitRange('bytes=0-1,4-5'), 'bytes=0-1,4-5');
    expect(StreamCacheRange.parse('bytes 0-9/10')!.length, 10);
    expect(StreamCacheRange.parse('bytes 0-10/10'), isNull);
  });
}
