
/// 歌词行数据模型
class LyricLine {
  /// 原始时间戳（毫秒），不受偏移量影响
  final int originalTimestamp;

  /// 应用偏移量后的时间戳（毫秒）
  int timestamp;

  /// 歌词文本
  final String text;

  LyricLine({required this.originalTimestamp, required this.text}) 
      : timestamp = originalTimestamp;

  @override
  String toString() {
    return 'LyricLine{timestamp: $timestamp, text: $text}';
  }
}
