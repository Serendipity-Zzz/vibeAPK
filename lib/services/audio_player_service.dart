import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class AudioPlayerService {
  final AudioPlayer _audioPlayer = AudioPlayer();

  AudioPlayer get audioPlayer => _audioPlayer;

  Stream<PlayerState> get playerStateStream => _audioPlayer.playerStateStream;

  Stream<Duration> get positionStream => _audioPlayer.positionStream;

  Stream<Duration> get bufferedPositionStream =>
      _audioPlayer.bufferedPositionStream;

  Stream<Duration?> get durationStream => _audioPlayer.durationStream;

  Future<String?> pickAndLoadAudio() async {
    debugPrint('Attempting to pick an audio file...');

    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.audio);
    } catch (error, stackTrace) {
      debugPrint('Failed to open file picker: $error');
      debugPrint('$stackTrace');
      throw Exception('无法打开文件选择器');
    }

    if (result == null || result.files.single.path == null) {
      debugPrint('File picker was cancelled.');
      return null;
    }

    final filePath = result.files.single.path!;
    debugPrint('File picked: $filePath');
    await loadAudioFromPath(filePath);
    return filePath;
  }

  Future<void> loadAudioFromPath(String filePath) async {
    try {
      await _audioPlayer.setFilePath(filePath);
      debugPrint('Audio source set successfully: $filePath');
    } catch (error, stackTrace) {
      debugPrint('Failed to load audio file: $error');
      debugPrint('$stackTrace');
      throw Exception('所选文件不是可播放的音频，或当前格式不受支持');
    }
  }

  Future<void> play() async {
    await _audioPlayer.play();
  }

  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
  }

  Future<void> seek(Duration position) async {
    await _audioPlayer.seek(position);
  }

  Future<void> setVolume(double volume) async {
    await _audioPlayer.setVolume(volume);
  }

  void dispose() {
    _audioPlayer.dispose();
  }
}
