part of 'local_relay_io.dart';

/// 一个播放器会话的按集预取。前台播放沿用 /play 并读取同一份磁盘缓存。
class PlaybackPrefetch {
  PlaybackPrefetch._(
    this._relay,
    this._cache,
    this._isPlaying,
    this._isBuffering,
  ) {
    _cache.protectPrefetch(_entries);
  }

  final LocalRelay _relay;
  final StreamDiskCache _cache;
  final bool Function() _isPlaying;
  final bool Function() _isBuffering;
  final _entries = <String>{};
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = false;
  bool _cancelled = false;

  bool get active => !_cancelled && _cache.enabled();

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _client.close(force: true);
    _cache.unprotectPrefetch(_entries);
    _entries.clear();
    _relay._prefetches.remove(this);
  }

  Future<bool> waitForBandwidth() async {
    // 暂停时播放器可能保留未读完的连接和转圈状态，预取仍可继续。
    while (active &&
        _isPlaying() &&
        (_isBuffering() || _relay._foregroundPlayRequests > 0)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return active;
  }

  /// 只有本集可完整读取并落盘才允许调度下一集。
  /// [onProgress] 报告从片头开始连续落盘的比例。文件用字节估算，HLS 用分片时长。
  Future<bool> episode(
    String url, {
    void Function(double fraction)? onProgress,
  }) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.origin != _relay.baseUrl ||
          uri.path != '/play' ||
          !active) {
        return false;
      }
      final query = uri.queryParameters;
      final target = _relay._playTarget(query);
      if (!_isHttp(target)) return false;
      final provider = (query['ck'] ?? '').trim();
      final headers = _relay._playHeaders(query, provider, target);
      final key = StreamDiskCache.keyOf(target);
      var offset = 0;
      int? total;
      do {
        if (!await waitForBandwidth()) return false;
        final range = offset == 0 && target.toLowerCase().contains('.m3u8')
            ? null
            : StreamDiskCache.limitRange('bytes=$offset-');
        final cached = range == null
            ? await _cache.lookup(key)
            : await _cache.lookupRange(key, range, allowPrefix: true);
        StreamCacheRange? span;
        if (cached != null) {
          if (!active) return false;
          _entries.add(cached.file.path);
          span = StreamCacheRange.parse(cached.contentRange);
          if (span == null) {
            onProgress?.call(1);
            return true;
          }
        } else {
          final opened = await _open(target, provider, headers, range);
          if (opened == null) return false;
          final response = opened.response;
          final contentType = _relay._responseContentType(response);
          if (offset == 0 &&
              response.statusCode < 300 &&
              (opened.finalUrl.toLowerCase().contains('.m3u8') ||
                  contentType.toLowerCase().contains('mpegurl'))) {
            final text = await _relay
                ._readHls(response, opened.finalUrl)
                .timeout(const Duration(seconds: 20));
            return await _hls(
              text,
              opened.finalUrl,
              provider,
              headers,
              onProgress,
            );
          }
          span = _contentRange(response);
          if (response.statusCode == 200 && offset == 0) {
            if (!await _store(key, response) || !active) return false;
            onProgress?.call(1);
            return true;
          }
          if (span == null ||
              span.start != offset ||
              (total != null && total != span.total)) {
            await response.listen((_) {}).cancel();
            return false;
          }
          if (!await _store(key, response, range: span)) return false;
        }
        if (total != null && total != span.total) return false;
        total = span.total;
        offset = span.end + 1;
        if (!active) return false;
        onProgress?.call(offset / total);
      } while (active && offset < total);
      return active && offset == total;
    } catch (_) {
      // 预取失败由前台的正常取链和中继流程接手。
      return false;
    }
  }

  Future<bool> _hls(
    String text,
    String base,
    String provider,
    Map<String, String> headers,
    void Function(double fraction)? onProgress,
  ) async {
    for (var depth = 0; isHlsMasterPlaylist(text); depth++) {
      // 独立音轨和多码率由实际播放器选择，避免预取一条不会被使用的流。
      final variants = RegExp(
        r'^#EXT-X-STREAM-INF:',
        multiLine: true,
      ).allMatches(text).length;
      if (depth >= 3 || variants != 1 || text.contains('#EXT-X-MEDIA:')) {
        return false;
      }
      final variant = pickHlsVariant(text, base);
      if (variant == null) return false;
      final opened = await _open(variant, provider, headers, null);
      if (opened == null) return false;
      if (opened.response.statusCode != 200) {
        await opened.response.listen((_) {}).cancel();
        return false;
      }
      base = opened.finalUrl;
      text = await _relay
          ._readHls(opened.response, base)
          .timeout(const Duration(seconds: 20));
    }
    if (!text.startsWith('#EXTM3U') ||
        !text.split('\n').any((line) => line.trim() == '#EXT-X-ENDLIST')) {
      return false;
    }
    final maps = text
        .split('\n')
        .where((line) => line.trimLeft().startsWith('#EXT-X-MAP:'));
    if (maps.length > 1 ||
        maps.any((line) => hlsAttribute(line, 'BYTERANGE') != null)) {
      return false;
    }
    final playlist = parseHlsMediaPlaylist(text, base);
    final init = playlist.initUri;
    if (init != null && !await _segment(init, provider, headers)) return false;
    final duration = playlist.segments.fold<double>(
      0,
      (sum, segment) => sum + segment.durationSeconds,
    );
    final hasTimeline =
        duration.isFinite &&
        playlist.segments.every((segment) => segment.durationSeconds > 0);
    var cachedDuration = 0.0;
    for (final segment in playlist.segments) {
      final keyUri = segment.keyUri;
      if (keyUri != null && !await _segment(keyUri, provider, headers)) {
        return false;
      }
      if (!await _segment(
        segment.url,
        provider,
        headers,
        range: segment.range?.value,
      )) {
        return false;
      }
      if (!active) return false;
      if (hasTimeline) {
        cachedDuration += segment.durationSeconds;
        onProgress?.call(cachedDuration / duration);
      }
    }
    if (active && !hasTimeline) onProgress?.call(1);
    return active && playlist.segments.isNotEmpty;
  }

  Future<bool> _segment(
    String target,
    String provider,
    Map<String, String> headers, {
    String? range,
  }) async {
    if (!_isHttp(target) || !await waitForBandwidth()) return false;
    final key = StreamDiskCache.keyOf(target);
    final cached = range == null
        ? await _cache.lookup(key)
        : await _cache.lookupRange(key, range);
    if (cached != null) {
      if (!active) return false;
      _entries.add(cached.file.path);
      return true;
    }
    final opened = await _open(target, provider, headers, range);
    if (opened == null) return false;
    final response = opened.response;
    final span = _contentRange(response);
    if ((range == null && response.statusCode == 200) ||
        (span != null && range == 'bytes=${span.start}-${span.end}')) {
      return _store(key, response, range: span);
    }
    await response.listen((_) {}).cancel();
    return false;
  }

  Future<({HttpClientResponse response, String finalUrl})?> _open(
    String target,
    String provider,
    Map<String, String> headers,
    String? range,
  ) async {
    if (!_isHttp(target) ||
        !await waitForBandwidth() ||
        _relay.isDeadPlayTarget(target)) {
      return null;
    }
    if (provider.isNotEmpty) {
      final refreshed = _relay._applyPlayCookieJar(
        provider,
        _relay._headerValue(headers, HttpHeaders.cookieHeader),
      );
      if (refreshed.isNotEmpty) {
        _relay._setHeader(headers, HttpHeaders.cookieHeader, refreshed);
      }
    }
    return _relay._openPlayWithSession(
      target,
      headers: headers,
      method: 'GET',
      range: range,
      provider: provider,
      client: _client,
    );
  }

  StreamCacheRange? _contentRange(HttpClientResponse response) =>
      response.statusCode == 206
      ? StreamCacheRange.parse(
          _relay._responseHeader(response, HttpHeaders.contentRangeHeader),
        )
      : null;

  Future<bool> _store(
    String key,
    HttpClientResponse response, {
    StreamCacheRange? range,
  }) async {
    final contentType = _relay._responseContentType(response);
    final writer =
        active &&
            LocalRelay._cacheableContentType(contentType) &&
            _relay
                ._responseHeader(response, HttpHeaders.contentEncodingHeader)
                .isEmpty
        ? await _cache.open(
            key,
            contentType: contentType,
            length: response.contentLength,
            range: range,
            prefetch: true,
          )
        : null;
    if (writer == null) {
      await response.listen((_) {}).cancel();
      return false;
    }
    var committed = false;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (!await waitForBandwidth()) return false;
        writer.add(chunk);
      }
      if (!active) return false;
      _entries.add(writer.entry.path);
      committed = await writer.commit();
      return committed && active;
    } finally {
      if (!committed) {
        _entries.remove(writer.entry.path);
        await writer.abort();
      }
    }
  }

  static bool _isHttp(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.isScheme('http') || uri.isScheme('https'));
  }
}
