
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// 音频服务类，封装了音频播放、控制和文件选择的逻辑。
class AudioPlayerService {
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// 获取音频播放器实例。
  AudioPlayer get audioPlayer => _audioPlayer;

  /// 播放状态流，用于UI更新。
  Stream<PlayerState> get playerStateStream => _audioPlayer.playerStateStream;

  /// 播放位置流。
  Stream<Duration> get positionStream => _audioPlayer.positionStream;

  /// 缓冲位置流。
  Stream<Duration> get bufferedPositionStream => _audioPlayer.bufferedPositionStream;

  /// 音频总时长流。
  Stream<Duration?> get durationStream => _audioPlayer.durationStream;

  /// 从本地文件系统选择并加载音频文件。
  ///
  /// 支持的文件类型: mp3, m4a, wav。
  /// 如果用户成功选择文件，则返回文件路径，否则返回 null。
  Future<String?> pickAndLoadAudio() async {
    try {
      // 使用 file_picker 选择文件
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowedExtensions: ['mp3', 'm4a', 'wav'],
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        // 设置音频源
        await _audioPlayer.setFilePath(filePath);
        return filePath;
      }
    } catch (e) {
      debugPrint("文件选择或加载失败: $e");
    }
    return null;
  }

  /// 播放音频。
  Future<void> play() async {
    await _audioPlayer.play();
  }

  /// 暂停音频。
  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  /// 停止音频。
  Future<void> stop() async {
    await _audioPlayer.stop();
  }

  /// 跳转到指定位置。
  ///
  /// [position] 要跳转到的目标位置。
  Future<void> seek(Duration position) async {
    await _audioPlayer.seek(position);
  }

  /// 设置音量。
  ///
  /// [volume] 音量值，范围从 0.0 到 1.0。
  Future<void> setVolume(double volume) async {
    await _audioPlayer.setVolume(volume);
  }

  /// 释放资源。
  ///
  /// 在服务不再需要时调用，以释放 _audioPlayer 占用的资源。
  void dispose() {
    _audioPlayer.dispose();
  }
}
