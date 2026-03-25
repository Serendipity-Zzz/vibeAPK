import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'lrc_service.dart';

class GequhaiService {
  GequhaiService({LrcService? lrcService})
      : _dio = Dio(
          BaseOptions(
            headers: <String, String>{
              HttpHeaders.userAgentHeader:
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/145.0.0.0 Safari/537.36',
              HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9,en;q=0.8',
              HttpHeaders.refererHeader: _baseUrl,
            },
            followRedirects: true,
            validateStatus: (status) => status != null && status < 500,
          ),
        ),
        _lrcService = lrcService ?? LrcService();

  static const String _baseUrl = 'https://www.gequhai.com';

  final Dio _dio;
  final LrcService _lrcService;
  final Map<String, GequhaiSongDetail> _detailCache =
      <String, GequhaiSongDetail>{};

  String buildSearchUrl(String query) {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return _baseUrl;
    }
    return '$_baseUrl/s/${Uri.encodeComponent(trimmedQuery)}';
  }

  Future<GequhaiSongDetail?> searchSong(String songName, String artist) async {
    final query = _buildSearchQuery(songName, artist);
    if (query.isEmpty) {
      return null;
    }

    for (final candidate in _buildCandidateQueries(query)) {
      final html = await _requestPage(buildSearchUrl(candidate));
      if (html == null) {
        continue;
      }

      final matches = parseSearchResults(html, query: candidate);
      if (matches.isEmpty) {
        continue;
      }

      for (final match in matches.take(3)) {
        final detail = await fetchSongDetail(match.pageUrl);
        if (detail != null) {
          return detail;
        }
      }
    }

    return null;
  }

  List<GequhaiSearchResult> parseSearchResults(
    String html, {
    String query = '',
  }) {
    final rowPattern = RegExp(
      r'<tr>\s*<td[^>]*>.*?</td>\s*<td>\s*<a href="(/play/\d+)"[^>]*>\s*(.*?)\s*</a>\s*</td>\s*<td[^>]*>\s*(.*?)\s*</td>',
      caseSensitive: false,
      dotAll: true,
    );

    final LinkedHashMap<String, GequhaiSearchResult> results =
        LinkedHashMap<String, GequhaiSearchResult>();

    for (final match in rowPattern.allMatches(html)) {
      final relativeUrl = match.group(1)!;
      final title = _stripHtml(match.group(2)!);
      final artist = _stripHtml(match.group(3)!);
      final pageUrl = Uri.parse(_baseUrl).resolve(relativeUrl).toString();
      final result = GequhaiSearchResult(
        pageUrl: pageUrl,
        title: title,
        artist: artist,
        score: _calculateMatchScore(query, title, artist),
      );

      final existing = results[pageUrl];
      if (existing == null || result.score > existing.score) {
        results[pageUrl] = result;
      }
    }

    final ordered = results.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return ordered;
  }

  Future<GequhaiSongDetail?> fetchSongDetail(String pageUrl) async {
    final cached = _detailCache[pageUrl];
    if (cached != null) {
      return cached;
    }

    final html = await _requestPage(pageUrl);
    if (html == null) {
      return null;
    }

    final detail = parseSongDetailHtml(html, pageUrl: pageUrl);
    if (detail != null) {
      _detailCache[pageUrl] = detail;
    }
    return detail;
  }

  GequhaiSongDetail? parseSongDetailHtml(
    String html, {
    required String pageUrl,
  }) {
    final title = _extractScriptValue(html, 'mp3_title');
    final artist = _extractScriptValue(html, 'mp3_author');
    final playId = _extractScriptValue(html, 'play_id');
    final rawLrc = _extractLrcBlock(html);

    if (title == null || artist == null || playId == null || rawLrc == null) {
      return null;
    }

    final decodedExtraUrl = _decodeModifiedBase64(
      _extractScriptValue(html, 'mp3_extra_url') ?? '',
    );

    return GequhaiSongDetail(
      pageUrl: pageUrl,
      title: title,
      artist: artist,
      playId: playId,
      lrcContent: _buildLrcContent(title, artist, rawLrc),
      highQualityHintUrl: decodedExtraUrl,
    );
  }

  Future<String?> downloadAndSaveLrc(
    GequhaiSongDetail detail, {
    String? fileName,
  }) {
    return _lrcService.saveLrcContent(
      fileName ?? detail.songIdentifier,
      detail.lrcContent,
      prefix: 'gequhai',
    );
  }

  Future<GequhaiAudioDownloadResult?> downloadAndSaveAudio(
    GequhaiSongDetail detail, {
    String? fileName,
  }) async {
    final resolved = await _resolveAudioCandidate(detail);
    if (resolved == null) {
      return null;
    }

    final cacheDir = await getApplicationCacheDirectory();
    final extension = _resolveAudioExtension(
      resolved.audioUrl,
      contentType: resolved.contentType,
    );
    final safeFileName = _sanitizeFileName(fileName ?? detail.songIdentifier);
    final targetPath = '${cacheDir.path}/gequhai_$safeFileName$extension';

    await _dio.download(
      resolved.audioUrl,
      targetPath,
      options: Options(
        headers: <String, String>{
          HttpHeaders.refererHeader: detail.pageUrl,
          HttpHeaders.userAgentHeader:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/145.0.0.0 Safari/537.36',
        },
      ),
    );

    return GequhaiAudioDownloadResult(
      filePath: targetPath,
      usedHighQuality: resolved.usedHighQuality,
      warningMessage: resolved.warningMessage,
    );
  }

  Future<_ResolvedAudioCandidate?> _resolveAudioCandidate(
    GequhaiSongDetail detail,
  ) async {
    if (detail.highQualityHintUrl != null &&
        detail.highQualityHintUrl!.isNotEmpty) {
      final audioUrl = await _tryResolveDirectAudioUrl(
        detail.highQualityHintUrl!,
        referer: detail.pageUrl,
      );
      if (audioUrl != null) {
        return _ResolvedAudioCandidate(
          audioUrl: audioUrl.url,
          contentType: audioUrl.contentType,
          usedHighQuality: true,
        );
      }
    }

    final highQualityApi = await _fetchApiAudioUrl(detail.playId, type: 1);
    if (highQualityApi != null) {
      return _ResolvedAudioCandidate(
        audioUrl: highQualityApi.url,
        contentType: highQualityApi.contentType,
        usedHighQuality: true,
        warningMessage:
            detail.highQualityHintUrl != null &&
                    detail.highQualityHintUrl!.contains('pan.quark.cn')
                ? '站点高品质入口为外部网盘，已回退到可直接导入的站内音频。'
                : null,
      );
    }

    final standardApi = await _fetchApiAudioUrl(detail.playId, type: 0);
    if (standardApi == null) {
      return null;
    }

    return _ResolvedAudioCandidate(
      audioUrl: standardApi.url,
      contentType: standardApi.contentType,
      usedHighQuality: false,
      warningMessage:
          detail.highQualityHintUrl != null &&
                  detail.highQualityHintUrl!.contains('pan.quark.cn')
              ? '站点高品质入口为外部网盘，已回退到标准音质导入。'
              : null,
    );
  }

  Future<_DirectAudioUrl?> _fetchApiAudioUrl(
    String playId, {
    required int type,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/api/music',
        data: <String, dynamic>{'id': playId, 'type': type},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: <String, String>{
            'X-Requested-With': 'XMLHttpRequest',
            'X-Custom-Header': 'SecretKey',
            HttpHeaders.refererHeader: _baseUrl,
          },
        ),
      );

      final data = response.data;
      if (response.statusCode != 200 ||
          data == null ||
          data['code'] != 200 ||
          data['data'] is! Map<String, dynamic>) {
        return null;
      }

      final audioUrl = (data['data'] as Map<String, dynamic>)['url'] as String?;
      if (audioUrl == null || audioUrl.isEmpty) {
        return null;
      }

      return _tryResolveDirectAudioUrl(audioUrl, referer: _baseUrl);
    } catch (error) {
      debugPrint('Failed to resolve Gequhai api music url: $error');
      return null;
    }
  }

  Future<_DirectAudioUrl?> _tryResolveDirectAudioUrl(
    String candidateUrl, {
    required String referer,
  }) async {
    if (!_looksLikeAudioUrl(candidateUrl)) {
      return null;
    }

    try {
      final response = await _dio.head<void>(
        candidateUrl,
        options: Options(
          headers: <String, String>{
            HttpHeaders.refererHeader: referer,
          },
        ),
      );
      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      if (contentType != null && contentType.toLowerCase().contains('audio')) {
        return _DirectAudioUrl(url: candidateUrl, contentType: contentType);
      }

      if (_looksLikeAudioUrl(candidateUrl)) {
        return _DirectAudioUrl(url: candidateUrl, contentType: contentType);
      }
    } catch (error) {
      debugPrint('Failed to validate audio url: $error');
      if (_looksLikeAudioUrl(candidateUrl)) {
        return _DirectAudioUrl(url: candidateUrl);
      }
    }

    return null;
  }

  Future<String?> _requestPage(String url) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode != 200 || response.data == null) {
        return null;
      }
      return response.data!;
    } catch (error) {
      debugPrint('Failed to fetch Gequhai page: $error');
      return null;
    }
  }

  String _buildSearchQuery(String songName, String artist) {
    final trimmedSongName = songName.trim();
    final trimmedArtist = artist.trim();
    if (trimmedSongName.isEmpty) {
      return '';
    }

    if (trimmedArtist.isEmpty || trimmedArtist.toLowerCase() == 'any') {
      return trimmedSongName;
    }

    return '$trimmedSongName $trimmedArtist'.trim();
  }

  Iterable<String> _buildCandidateQueries(String query) sync* {
    final LinkedHashSet<String> candidates = LinkedHashSet<String>();

    void addCandidate(String value) {
      final candidate = value.trim();
      if (candidate.isNotEmpty) {
        candidates.add(candidate);
      }
    }

    addCandidate(query);

    final normalized = query
        .replaceAll(RegExp(r'[_|/\\]+'), ' ')
        .replaceAll(RegExp(r'\s*-+\s*'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    addCandidate(normalized);

    for (final segment in query.split(RegExp(r'[-|/\\]'))) {
      addCandidate(segment);
    }

    final words = normalized
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    for (int start = 1; start < words.length; start++) {
      addCandidate(words.sublist(start).join(' '));
    }
    for (int end = words.length - 1; end > 0; end--) {
      addCandidate(words.sublist(0, end).join(' '));
    }

    yield* candidates;
  }

  int _calculateMatchScore(String query, String title, String artist) {
    final normalizedQuery = _normalizeForComparison(query);
    final normalizedTitle = _normalizeForComparison(title);
    final normalizedArtist = _normalizeForComparison(artist);

    int score = 0;
    if (normalizedQuery == normalizedTitle && normalizedQuery.isNotEmpty) {
      score += 100;
    }
    if (normalizedTitle.isNotEmpty &&
        normalizedQuery.contains(normalizedTitle)) {
      score += 60;
    }
    if (normalizedQuery.isNotEmpty &&
        normalizedTitle.contains(normalizedQuery)) {
      score += 30;
    }
    if (normalizedArtist.isNotEmpty &&
        normalizedQuery.contains(normalizedArtist)) {
      score += 20;
    }
    return score;
  }

  String? _extractScriptValue(String html, String field) {
    final match = RegExp(
      "window\\.$field\\s*=\\s*'([^']*)'",
      dotAll: true,
    ).firstMatch(html);
    if (match == null) {
      return null;
    }

    return _decodeHtmlEntities(match.group(1)!);
  }

  String? _extractLrcBlock(String html) {
    final match = RegExp(
      r'id="content-lrc2">(.*?)</div>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (match == null) {
      return null;
    }

    return _decodeHtmlEntities(
      match.group(1)!
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('\r', '')
          .trim(),
    );
  }

  String _buildLrcContent(String title, String artist, String rawLrc) {
    final lines = rawLrc
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final buffer = StringBuffer()
      ..writeln('[ti:$title]')
      ..writeln('[ar:$artist]')
      ..writeln('[by:gequhai.com]')
      ..writeln();

    for (final line in lines) {
      buffer.writeln(line);
    }

    return buffer.toString().trim();
  }

  String? _decodeModifiedBase64(String value) {
    if (value.isEmpty) {
      return null;
    }

    try {
      final normalized = value.replaceAll('#', 'H').replaceAll('%', 'S');
      return utf8.decode(base64Decode(normalized));
    } catch (error) {
      debugPrint('Failed to decode high quality url hint: $error');
      return null;
    }
  }

  bool _looksLikeAudioUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.endsWith('.mp3') ||
        lowerUrl.endsWith('.aac') ||
        lowerUrl.endsWith('.m4a') ||
        lowerUrl.endsWith('.flac') ||
        lowerUrl.endsWith('.wav');
  }

  String _resolveAudioExtension(String url, {String? contentType}) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final extension in <String>['.mp3', '.aac', '.m4a', '.flac', '.wav']) {
      if (path.endsWith(extension)) {
        return extension;
      }
    }

    final lowerContentType = contentType?.toLowerCase() ?? '';
    if (lowerContentType.contains('aac')) {
      return '.aac';
    }
    if (lowerContentType.contains('mpeg') || lowerContentType.contains('mp3')) {
      return '.mp3';
    }
    if (lowerContentType.contains('mp4') || lowerContentType.contains('m4a')) {
      return '.m4a';
    }
    if (lowerContentType.contains('flac')) {
      return '.flac';
    }
    if (lowerContentType.contains('wav')) {
      return '.wav';
    }

    return '.mp3';
  }

  String _sanitizeFileName(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _stripHtml(String value) {
    return _decodeHtmlEntities(
      value
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
    );
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }

  String _normalizeForComparison(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
  }
}

class GequhaiSearchResult {
  const GequhaiSearchResult({
    required this.pageUrl,
    required this.title,
    required this.artist,
    required this.score,
  });

  final String pageUrl;
  final String title;
  final String artist;
  final int score;
}

class GequhaiSongDetail {
  const GequhaiSongDetail({
    required this.pageUrl,
    required this.title,
    required this.artist,
    required this.playId,
    required this.lrcContent,
    this.highQualityHintUrl,
  });

  final String pageUrl;
  final String title;
  final String artist;
  final String playId;
  final String lrcContent;
  final String? highQualityHintUrl;

  String get songIdentifier => '$title-$artist';
}

class GequhaiAudioDownloadResult {
  const GequhaiAudioDownloadResult({
    required this.filePath,
    required this.usedHighQuality,
    this.warningMessage,
  });

  final String filePath;
  final bool usedHighQuality;
  final String? warningMessage;
}

class _DirectAudioUrl {
  const _DirectAudioUrl({
    required this.url,
    this.contentType,
  });

  final String url;
  final String? contentType;
}

class _ResolvedAudioCandidate {
  const _ResolvedAudioCandidate({
    required this.audioUrl,
    this.contentType,
    required this.usedHighQuality,
    this.warningMessage,
  });

  final String audioUrl;
  final String? contentType;
  final bool usedHighQuality;
  final String? warningMessage;
}
