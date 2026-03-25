import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/lyric_line.dart';

class LrcService {
  static final RegExp _timestampRegex = RegExp(
    r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );

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
      debugPrint('Failed to load LRC from file: $error');
      return <LyricLine>[];
    }
  }

  Future<String?> pickLrcFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['lrc'],
      );
      if (result == null || result.files.single.path == null) {
        return null;
      }

      return result.files.single.path!;
    } catch (error) {
      debugPrint('Failed to pick LRC file: $error');
      throw Exception('无法打开歌词文件选择器');
    }
  }

  Future<String> saveLrcContent(
    String fileName,
    String lrcContent, {
    String prefix = 'lrc',
  }) async {
    final cacheDir = await getApplicationCacheDirectory();
    final safeFileName = _sanitizeFileName(fileName);
    final filePath = '${cacheDir.path}/${prefix}_$safeFileName.lrc';
    final file = File(filePath);
    await file.writeAsString(lrcContent);
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

  String _sanitizeFileName(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
