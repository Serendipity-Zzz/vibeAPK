
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lyric_line.dart';

/// 歌词滚动与对齐服务
class LyricScrollService {
  final ScrollController scrollController = ScrollController();

  /// 应用歌词偏移量
  /// 
  /// [lyrics] 歌词列表
  /// [offsetMs] 偏移量（毫秒）
  void applyOffset(List<LyricLine> lyrics, int offsetMs) {
    for (var line in lyrics) {
      line.timestamp = line.originalTimestamp + offsetMs;
    }
    // 重新排序以防偏移量导致顺序错乱
    lyrics.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// 保存指定歌曲的歌词偏移量
  /// 
  /// [songIdentifier] 歌曲的唯一标识符（如文件名）
  /// [offsetMs] 要保存的偏移量
  Future<void> saveLyricOffset(String songIdentifier, int offsetMs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lyric_offset_$songIdentifier', offsetMs);
  }

  /// 加载指定歌曲的歌词偏移量
  /// 
  /// [songIdentifier] 歌曲的唯一标识符
  /// 返回保存的偏移量，如果不存在则返回 0
  Future<int> loadLyricOffset(String songIdentifier) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('lyric_offset_$songIdentifier') ?? 0;
  }

  /// 滚动到指定的歌词行
  /// 
  /// [index] 目标歌词行的索引
  /// [itemHeight] 每一行歌词的高度
  void scrollTo(int index, double itemHeight) {
    if (scrollController.hasClients) {
      final screenHeight = scrollController.position.viewportDimension;
      // 计算目标位置，使当前行居中
      final targetPosition = index * itemHeight - (screenHeight / 2) + (itemHeight / 2);
      
      scrollController.animateTo(
        targetPosition,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void dispose() {
    scrollController.dispose();
  }
}
