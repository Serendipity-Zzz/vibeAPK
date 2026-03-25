import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/lyric_line.dart';

class LrcService {
  LrcService()
      : _dio = Dio(
          BaseOptions(
            headers: <String, String>{
              HttpHeaders.userAgentHeader:
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/145.0.0.0 Safari/537.36',
              HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9,en;q=0.8',
            },
            followRedirects: true,
            validateStatus: (status) => status != null && status < 600,
          ),
        );

  static const String _baseUrl = 'https://www.lyricsify.com';
  static final RegExp _timestampRegex = RegExp(
    r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _metadataRegex = RegExp(
    r'^\[(ti|ar|al|by|offset):.*\]$',
    caseSensitive: false,
  );

  final Dio _dio;

  String buildSearchUrl(String query) {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return _baseUrl;
    }

    return '$_baseUrl/search?q=${Uri.encodeQueryComponent(normalizedQuery)}';
  }

  Future<String?> searchLrc(String songName, String artist) async {
    final query = _buildSearchQuery(songName, artist);
    if (query.isEmpty) {
      return null;
    }

    LyricsFetchException? verificationError;
    for (final candidate in _buildCandidateQueries(query)) {
      final searchUrl = buildSearchUrl(candidate);
      try {
        final html = await _requestPage(searchUrl);
        if (html == null) {
          continue;
        }

        final matches = _extractLyricsLinks(html, candidate);
        if (matches.isEmpty) {
          continue;
        }

        final bestMatch = matches.first;
        debugPrint(
          "Matched Lyricsify page '${bestMatch.title}' by '${bestMatch.artist}' -> ${bestMatch.url}",
        );
        return bestMatch.url;
      } on LyricsFetchException catch (error) {
        if (error.requiresVerification) {
          verificationError ??= error;
          break;
        }
        rethrow;
      }
    }

    if (verificationError != null) {
      throw verificationError;
    }

    debugPrint("No Lyricsify result found for query: $query");
    return null;
  }

  Future<String?> downloadAndSaveLrc(String url, String fileName) async {
    try {
      final html = await _requestPage(url);
      if (html == null) {
        return null;
      }

      var lrcContent = _extractLrcContent(
        html: html,
        pageTitle: _extractPageTitle(html),
        fileName: fileName,
      );

      if (lrcContent == null) {
        final lrcUrl = extractLrcDownloadUrl(html, currentUrl: url);
        if (lrcUrl != null) {
          final lrcResponse = await _requestPage(lrcUrl);
          if (lrcResponse != null) {
            lrcContent = _extractLrcContent(
              html: lrcResponse,
              pageTitle: _extractPageTitle(html),
              fileName: fileName,
            );
          }
        }
      }

      if (lrcContent == null) {
        debugPrint("Lyricsify page did not expose a timed LRC payload: $url");
        return null;
      }

      return _writeLrcFile(fileName, lrcContent);
    } on LyricsFetchException {
      rethrow;
    } catch (error) {
      debugPrint("Failed to download or save Lyricsify LRC: $error");
      return null;
    }
  }

  Future<String?> saveLrcFromPageHtml({
    required String html,
    required String fileName,
    String? pageUrl,
    String? pageTitle,
    String? pageText,
  }) async {
    if (_looksLikeVerificationPage(html) ||
        (pageText != null && _looksLikeVerificationPage(pageText))) {
      throw LyricsFetchException(
        'Lyricsify 当前仍在验证页，请先完成人机验证并打开歌词页面。',
        requiresVerification: true,
        verificationUrl: pageUrl,
      );
    }

    final lrcContent = _extractLrcContent(
      html: html,
      pageText: pageText,
      pageTitle: pageTitle,
      fileName: fileName,
    );
    if (lrcContent == null) {
      return null;
    }

    return _writeLrcFile(fileName, lrcContent);
  }

  String? extractFirstLyricsPageUrl(String html, {String? currentUrl}) {
    final matches = _extractLyricsLinks(html, '');
    if (matches.isEmpty) {
      return null;
    }

    return matches.first.url;
  }

  String? extractLrcDownloadUrl(String html, {String? currentUrl}) {
    final match = RegExp(
      r'href="([^"]*(?:\.lrc|/lrc/[^"]+))"',
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) {
      return null;
    }

    final rawHref = _decodeHtmlEntities(match.group(1)!).trim();
    if (rawHref.isEmpty || rawHref == '/lrc') {
      return null;
    }

    final baseUri = Uri.parse(currentUrl ?? _baseUrl);
    return baseUri.resolve(rawHref).toString();
  }

  List<LyricLine> parseLrc(String lrcContent) {
    final List<LyricLine> lyrics = <LyricLine>[];

    for (final line in lrcContent.split('\n')) {
      final matches = _timestampRegex.allMatches(line);
      if (matches.isEmpty) {
        continue;
      }

      final text = line.substring(matches.last.end).trim();
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3);
        final milliseconds = _fractionToMilliseconds(fraction);
        final totalMilliseconds =
            minutes * 60 * 1000 + seconds * 1000 + milliseconds;
        lyrics.add(
          LyricLine(originalTimestamp: totalMilliseconds, text: text),
        );
      }
    }

    lyrics.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lyrics;
  }

  Future<List<LyricLine>> loadLrcFromFile(String filePath) async {
    try {
      final file = File(filePath);
      final content = await file.readAsString();
      return parseLrc(content);
    } catch (error) {
      debugPrint("Failed to load LRC from file: $error");
      return <LyricLine>[];
    }
  }

  Future<String?> _requestPage(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final body = response.data ?? '';

    if (_looksLikeVerificationPage(body, statusCode: response.statusCode)) {
      throw LyricsFetchException(
        'Lyricsify 触发了人机验证，请在弹出的浏览器中完成验证后再导入。',
        requiresVerification: true,
        verificationUrl: url,
      );
    }

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode != 200) {
      debugPrint(
        'Lyricsify request failed with status ${response.statusCode}: $url',
      );
      return null;
    }

    return body;
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

    final normalizedSeparators = query
        .replaceAll(RegExp(r'[_|/\\]+'), ' ')
        .replaceAll(RegExp(r'\s*-+\s*'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    addCandidate(normalizedSeparators);

    for (final segment in query.split(RegExp(r'[-|/\\]'))) {
      addCandidate(segment);
    }

    final words = normalizedSeparators
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

  List<_LyricsLinkCandidate> _extractLyricsLinks(String html, String query) {
    final matches = RegExp(
      r'<a[^>]+href="(/lyrics/[^"]+)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(html);

    final LinkedHashMap<String, _LyricsLinkCandidate> candidates =
        LinkedHashMap<String, _LyricsLinkCandidate>();
    for (final match in matches) {
      final relativeUrl = match.group(1)!;
      final anchorHtml = match.group(2)!;
      final title = _extractTagText(anchorHtml, 'strong');
      final artist = _extractTagText(anchorHtml, 'small');
      final readableText = _stripHtml(anchorHtml);

      final candidate = _LyricsLinkCandidate(
        url: Uri.parse(_baseUrl).resolve(relativeUrl).toString(),
        title: title.isEmpty ? readableText : title,
        artist: artist,
        score: _calculateMatchScore(
          query,
          title.isEmpty ? readableText : title,
          artist,
          relativeUrl,
        ),
      );

      final existing = candidates[candidate.url];
      if (existing == null || candidate.score > existing.score) {
        candidates[candidate.url] = candidate;
      }
    }

    final ordered = candidates.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return ordered;
  }

  String? _extractLrcContent({
    required String html,
    String? pageText,
    String? pageTitle,
    String? fileName,
  }) {
    final sources = <String>[
      if (pageText != null && pageText.trim().isNotEmpty) pageText,
      html,
      _stripHtml(html),
    ];

    for (final source in sources) {
      final lines = _extractLrcLines(source);
      final timedLineCount =
          lines.where((line) => _timestampRegex.hasMatch(line)).length;
      if (timedLineCount < 2) {
        continue;
      }

      return _composeLrcContent(
        lines,
        title: _resolveTitle(pageTitle, html, fileName),
        artist: _resolveArtist(html),
      );
    }

    return null;
  }

  List<String> _extractLrcLines(String source) {
    final normalized = _decodeHtmlEntities(
      source
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(
            RegExp(r'</(div|p|li|tr|section|article|pre|span|h\d)>',
                caseSensitive: false),
            '\n',
          )
          .replaceAll(RegExp(r'<[^>]+>'), '\n')
          .replaceAll('\\r', '')
          .replaceAll('\\n', '\n'),
    );

    final lines = normalized
        .split(RegExp(r'\n+'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final ordered = <String>{};
    for (final line in lines) {
      if (_metadataRegex.hasMatch(line)) {
        ordered.add(line);
        continue;
      }

      if (_timestampRegex.hasMatch(line)) {
        ordered.add(_normalizeTimedLine(line));
      }
    }

    return ordered.toList();
  }

  String _composeLrcContent(
    List<String> lines, {
    required String title,
    required String artist,
  }) {
    final metadataLines = lines.where(_metadataRegex.hasMatch).toList();
    final timedLines = lines.where((line) => _timestampRegex.hasMatch(line)).toList();

    final buffer = StringBuffer();
    final hasTitle = metadataLines.any(
      (line) => line.toLowerCase().startsWith('[ti:'),
    );
    final hasArtist = metadataLines.any(
      (line) => line.toLowerCase().startsWith('[ar:'),
    );
    final hasBy = metadataLines.any(
      (line) => line.toLowerCase().startsWith('[by:'),
    );

    if (!hasTitle && title.isNotEmpty) {
      buffer.writeln('[ti:$title]');
    }
    if (!hasArtist && artist.isNotEmpty) {
      buffer.writeln('[ar:$artist]');
    }
    if (!hasBy) {
      buffer.writeln('[by:lyricsify.com]');
    }

    for (final line in metadataLines) {
      final lower = line.toLowerCase();
      if (!hasTitle && lower.startsWith('[ti:')) {
        continue;
      }
      if (!hasArtist && lower.startsWith('[ar:')) {
        continue;
      }
      if (!hasBy && lower.startsWith('[by:')) {
        continue;
      }
      buffer.writeln(line);
    }

    if (timedLines.isNotEmpty) {
      buffer.writeln();
    }
    for (final line in timedLines) {
      buffer.writeln(line);
    }

    return buffer.toString().trim();
  }

  Future<String> _writeLrcFile(String fileName, String lrcContent) async {
    final cacheDir = await getApplicationCacheDirectory();
    final safeFileName = _sanitizeFileName(fileName);
    final filePath = '${cacheDir.path}/lyricsify_$safeFileName.lrc';
    final file = File(filePath);
    await file.writeAsString(lrcContent);
    debugPrint("Saved Lyricsify LRC file to: $filePath");
    return filePath;
  }

  int _fractionToMilliseconds(String? fraction) {
    if (fraction == null || fraction.isEmpty) {
      return 0;
    }

    if (fraction.length == 1) {
      return int.parse(fraction) * 100;
    }
    if (fraction.length == 2) {
      return int.parse(fraction) * 10;
    }
    return int.parse(fraction.substring(0, 3));
  }

  String _normalizeTimedLine(String line) {
    return line.replaceAllMapped(_timestampRegex, (match) {
      final minutes = match.group(1)!.padLeft(2, '0');
      final seconds = match.group(2)!;
      final fraction = match.group(3);
      if (fraction == null || fraction.isEmpty) {
        return '[$minutes:$seconds.00]';
      }
      if (fraction.length == 1) {
        return '[$minutes:$seconds.${fraction}00]';
      }
      if (fraction.length == 2) {
        return '[$minutes:$seconds.${fraction}0]';
      }
      return '[$minutes:$seconds.${fraction.substring(0, 3)}]';
    });
  }

  String _resolveTitle(String? pageTitle, String html, String? fileName) {
    final candidates = <String>[
      ?pageTitle,
      _extractPageTitle(html),
      ?fileName,
      '',
    ];

    for (final candidate in candidates) {
      final cleaned = candidate
          .replaceAll(RegExp(r'\s+LRC\s+Lyrics', caseSensitive: false), '')
          .replaceAll(RegExp(r'\s*\|\s*Lyricsify.*$', caseSensitive: false), '')
          .replaceAll(RegExp(r'\s+-\s+Lyricsify.*$', caseSensitive: false), '')
          .trim();
      if (cleaned.isNotEmpty) {
        return cleaned;
      }
    }

    return '';
  }

  String _resolveArtist(String html) {
    final small = _extractTagText(html, 'small');
    if (small.isNotEmpty) {
      return small;
    }

    final title = _extractPageTitle(html);
    final match = RegExp(r'^(.*?)\s+-\s+(.*?)\s+LRC\s+Lyrics$',
        caseSensitive: false).firstMatch(title);
    if (match != null) {
      return match.group(1)!.trim();
    }

    return '';
  }

  String _extractPageTitle(String html) {
    final h1Match = RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true).firstMatch(html);
    if (h1Match != null) {
      final title = _stripHtml(h1Match.group(1)!);
      if (title.isNotEmpty) {
        return title;
      }
    }

    final titleMatch =
        RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true).firstMatch(html);
    if (titleMatch == null) {
      return '';
    }

    return _stripHtml(titleMatch.group(1)!);
  }

  String _extractTagText(String html, String tagName) {
    final match = RegExp(
      '<$tagName[^>]*>(.*?)</$tagName>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (match == null) {
      return '';
    }

    return _stripHtml(match.group(1)!);
  }

  int _calculateMatchScore(
    String query,
    String title,
    String artist,
    String relativeUrl,
  ) {
    final normalizedQuery = _normalizeForComparison(query);
    final normalizedTitle = _normalizeForComparison(title);
    final normalizedArtist = _normalizeForComparison(artist);
    final normalizedUrl = _normalizeForComparison(relativeUrl);

    int score = 0;
    if (normalizedQuery.isNotEmpty && normalizedQuery == normalizedTitle) {
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
    if (normalizedUrl.contains(normalizedQuery) && normalizedQuery.isNotEmpty) {
      score += 15;
    }
    return score;
  }

  bool _looksLikeVerificationPage(String body, {int? statusCode}) {
    final loweredBody = body.toLowerCase();
    return statusCode == 403 ||
        loweredBody.contains('just a moment') ||
        loweredBody.contains('performing security verification') ||
        loweredBody.contains('enable javascript and cookies to continue') ||
        loweredBody.contains('cf-browser-verification') ||
        loweredBody.contains('cloudflare');
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

class LyricsFetchException implements Exception {
  const LyricsFetchException(
    this.message, {
    this.requiresVerification = false,
    this.verificationUrl,
  });

  final String message;
  final bool requiresVerification;
  final String? verificationUrl;

  @override
  String toString() => message;
}

class _LyricsLinkCandidate {
  const _LyricsLinkCandidate({
    required this.url,
    required this.title,
    required this.artist,
    required this.score,
  });

  final String url;
  final String title;
  final String artist;
  final int score;
}
