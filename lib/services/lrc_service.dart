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
            validateStatus: (status) => status != null && status < 500,
          ),
        );

  static const String _baseUrl = 'https://geciyi.com';

  final Dio _dio;
  final Map<String, _LyricsPageData> _pageCache = <String, _LyricsPageData>{};

  Future<String?> searchLrc(String songName, String artist) async {
    final query = _buildSearchQuery(songName, artist);
    if (query.isEmpty) {
      return null;
    }

    _LyricsPageData? bestMatch;
    for (final candidate in _buildCandidateQueries(query)) {
      final page = await _fetchLyricsPage(candidate);
      if (page == null || !page.hasTimedLyrics) {
        continue;
      }

      if (bestMatch == null || page.score > bestMatch.score) {
        bestMatch = page;
      }

      if (page.score >= 120) {
        break;
      }
    }

    if (bestMatch == null) {
      debugPrint("No timed lyrics found on geciyi for query: $query");
      return null;
    }

    _pageCache[bestMatch.url] = bestMatch;
    debugPrint(
      "Matched lyrics page '${bestMatch.title}' by '${bestMatch.artist}' -> ${bestMatch.url}",
    );
    return bestMatch.url;
  }

  Future<String?> downloadAndSaveLrc(String url, String fileName) async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final safeFileName = _sanitizeFileName(fileName);
      final filePath = '${cacheDir.path}/$safeFileName.lrc';
      final file = File(filePath);

      if (await file.exists()) {
        debugPrint("Using cached LRC file: $filePath");
        return filePath;
      }

      final page = _pageCache[url] ?? await _fetchLyricsPageByUrl(url);
      if (page == null || !page.hasTimedLyrics) {
        debugPrint("Lyrics page does not contain timed lyrics: $url");
        return null;
      }

      final lrcContent = _buildLrcContent(page);
      if (lrcContent.isEmpty) {
        debugPrint("Failed to build LRC content for: $url");
        return null;
      }

      await file.writeAsString(lrcContent);
      debugPrint("Saved LRC file to: $filePath");
      return filePath;
    } catch (error) {
      debugPrint("Failed to download or save LRC: $error");
      return null;
    }
  }

  List<LyricLine> parseLrc(String lrcContent) {
    final List<LyricLine> lyrics = <LyricLine>[];
    final RegExp timeRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\]');

    for (final line in lrcContent.split('\n')) {
      final matches = timeRegex.allMatches(line);
      if (matches.isEmpty) {
        continue;
      }

      final text = line.substring(matches.last.end).trim();
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3)!;
        final milliseconds =
            fraction.length == 2 ? int.parse(fraction) * 10 : int.parse(fraction);
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

    for (final word in words) {
      addCandidate(word);
    }

    yield* candidates;
  }

  Future<_LyricsPageData?> _fetchLyricsPage(String query) async {
    final url = '$_baseUrl/lyrics/${Uri.encodeComponent(query)}';
    return _fetchLyricsPageByUrl(url, query: query);
  }

  Future<_LyricsPageData?> _fetchLyricsPageByUrl(
    String url, {
    String? query,
  }) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode != 200 || response.data == null) {
        return null;
      }

      final html = response.data!;
      final title = _extractTitle(html);
      final artist = _extractArtist(html);
      final lyricLines = _extractLyricLines(html);
      final timestamps = _extractTimestamps(html);

      if (title == null || lyricLines.isEmpty) {
        return null;
      }

      return _LyricsPageData(
        url: url,
        title: title,
        artist: artist,
        lyricLines: lyricLines,
        timestamps: timestamps,
        score: _calculateMatchScore(
          query ?? '$title $artist',
          title,
          artist,
          lyricLines.length,
          timestamps.length,
        ),
      );
    } catch (error) {
      debugPrint("Failed to fetch lyrics page '$url': $error");
      return null;
    }
  }

  String? _extractTitle(String html) {
    final match = RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true).firstMatch(html);
    if (match == null) {
      return null;
    }
    return _stripHtml(match.group(1)!);
  }

  String _extractArtist(String html) {
    final titleBlockMatch = RegExp(
      r'<h1[^>]*>.*?</h1>\s*<p[^>]*>(.*?)</p>',
      dotAll: true,
    ).firstMatch(html);
    if (titleBlockMatch == null) {
      return '';
    }
    return _stripHtml(titleBlockMatch.group(1)!);
  }

  List<String> _extractLyricLines(String html) {
    final matches = RegExp(
      r'<div class="original-text[^"]*">(.*?)</div>',
      dotAll: true,
    ).allMatches(html);

    final lines = matches.map((match) => _stripHtml(match.group(1)!)).toList();
    if (lines.isNotEmpty) {
      return lines;
    }

    final fallbackMatches = RegExp(
      r'<div class="lyrics-line[^"]*">(.*?)</div>',
      dotAll: true,
    ).allMatches(html);

    return fallbackMatches
        .map((match) => _stripHtml(match.group(1)!))
        .toList();
  }

  List<String> _extractTimestamps(String html) {
    final match = RegExp(
      r"window\.lyrics_time\s*=\s*'([^']*)';",
      dotAll: true,
    ).firstMatch(html);
    if (match == null) {
      return <String>[];
    }

    final raw = match.group(1)!;
    final timestampMatches =
        RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\]').allMatches(raw).toList();
    return timestampMatches
        .map((timestampMatch) => timestampMatch.group(0)!)
        .toList();
  }

  int _calculateMatchScore(
    String query,
    String title,
    String artist,
    int lyricCount,
    int timestampCount,
  ) {
    final normalizedQuery = _normalizeForComparison(query);
    final normalizedTitle = _normalizeForComparison(title);
    final normalizedArtist = _normalizeForComparison(artist);

    int score = 0;
    if (normalizedQuery == normalizedTitle) {
      score += 100;
    }
    if (normalizedQuery.contains(normalizedTitle) && normalizedTitle.isNotEmpty) {
      score += 60;
    }
    if (normalizedTitle.contains(normalizedQuery) && normalizedQuery.isNotEmpty) {
      score += 30;
    }
    if (normalizedArtist.isNotEmpty &&
        normalizedQuery.contains(normalizedArtist)) {
      score += 20;
    }
    if (lyricCount > 0) {
      score += 10;
    }
    if (timestampCount == lyricCount && timestampCount > 0) {
      score += 25;
    } else if (timestampCount > 0) {
      score += 10;
    }
    return score;
  }

  String _buildLrcContent(_LyricsPageData page) {
    if (!page.hasTimedLyrics) {
      return '';
    }

    final buffer = StringBuffer()
      ..writeln('[ti:${page.title}]')
      ..writeln('[ar:${page.artist}]')
      ..writeln('[by:geciyi.com]')
      ..writeln();

    final lineCount = page.timestamps.length < page.lyricLines.length
        ? page.timestamps.length
        : page.lyricLines.length;

    for (int i = 0; i < lineCount; i++) {
      final text = page.lyricLines[i].trim();
      buffer.writeln('${page.timestamps[i]}$text');
    }

    return buffer.toString().trim();
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

class _LyricsPageData {
  const _LyricsPageData({
    required this.url,
    required this.title,
    required this.artist,
    required this.lyricLines,
    required this.timestamps,
    required this.score,
  });

  final String url;
  final String title;
  final String artist;
  final List<String> lyricLines;
  final List<String> timestamps;
  final int score;

  bool get hasTimedLyrics => timestamps.isNotEmpty && lyricLines.isNotEmpty;
}
