
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/lyric_line.dart';

/// LRC 服务类，负责歌词的搜索、下载、解析和存储。
class LrcService {
  final Dio _dio = Dio();

  /// 模拟网络搜索，返回一个固定的 LRC 文件 URL。
  ///
  /// [songName] 歌曲名，用于模拟搜索。
  /// [artist] 歌手名，用于模拟搜索。
  Future<String?> searchLrc(String songName, String artist) async {
    // 在真实应用中，这里会调用一个真实的 API 来搜索 LRC 文件。
    // 这里我们返回一个固定的 URL 用于演示。
    debugPrint("正在搜索歌曲 '$songName' - '$artist' 的歌词...");
    return "https://raw.githubusercontent.com/we-flutter/flutter_lrc/master/example/res/gecishili.lrc";
  }

  /// 下载并存储 LRC 文件。
  ///
  /// [url] LRC 文件的 URL。
  /// [fileName] 用于存储的文件名。
  /// 如果文件已存在，则直接返回本地路径，否则下载并返回路径。
  Future<String?> downloadAndSaveLrc(String url, String fileName) async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final filePath = '${cacheDir.path}/$fileName.lrc';
      final file = File(filePath);

      // 如果文件已存在，则直接返回路径
      if (await file.exists()) {
        debugPrint("LRC 文件已存在于本地缓存: $filePath");
        return filePath;
      }

      // 下载文件
      debugPrint("正在从 $url 下载 LRC 文件...");
      final response = await _dio.get(url);
      await file.writeAsString(response.data);
      debugPrint("LRC 文件已保存到: $filePath");
      return filePath;
    } catch (e) {
      debugPrint("LRC 文件下载或保存失败: $e");
      return null;
    }
  }

  /// 解析 LRC 文件内容。
  ///
  /// [lrcContent] LRC 文件的字符串内容。
  /// 返回一个按时间戳排序的 LyricLine 列表。
  List<LyricLine> parseLrc(String lrcContent) {
    final List<LyricLine> lyrics = [];
    // 正则表达式，用于匹配 [mm:ss.xx] 格式的时间标签
    final RegExp timeRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\]');

    for (final line in lrcContent.split('\n')) {
      final matches = timeRegex.allMatches(line);
      if (matches.isNotEmpty) {
        // 获取歌词文本（时间标签之后的部分）
        final text = line.substring(matches.last.end).trim();
        for (final match in matches) {
          final minutes = int.parse(match.group(1)!);
          final seconds = int.parse(match.group(2)!);
          final milliseconds = int.parse(match.group(3)!);
          // 将时间转换为总毫秒数
          final totalMilliseconds = minutes * 60 * 1000 + seconds * 1000 + milliseconds;
          lyrics.add(LyricLine(originalTimestamp: totalMilliseconds, text: text));
        }
      }
    }

    // 按时间戳排序
    lyrics.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lyrics;
  }

  /// 从本地文件路径加载并解析 LRC 文件。
  ///
  /// [filePath] LRC 文件的本地路径。
  Future<List<LyricLine>> loadLrcFromFile(String filePath) async {
    try {
      final file = File(filePath);
      final content = await file.readAsString();
      return parseLrc(content);
    } catch (e) {
      debugPrint("从本地文件加载 LRC 失败: $e");
      return [];
    }
  }
}
