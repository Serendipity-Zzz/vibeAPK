import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class AudioPlayerService {
  AudioPlayerService()
      : _audioPlayer = AudioPlayer(
          userAgent:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
        );

  final AudioPlayer _audioPlayer;
  // ignore: experimental_member_use
  LockCachingAudioSource? _remoteAudioSource;
  String? _localAudioPath;

  AudioPlayer get audioPlayer => _audioPlayer;

  Stream<PlayerState> get playerStateStream => _audioPlayer.playerStateStream;

  Stream<Duration> get positionStream => _audioPlayer.positionStream;

  Stream<Duration> get bufferedPositionStream =>
      _audioPlayer.bufferedPositionStream;

  Stream<Duration?> get durationStream => _audioPlayer.durationStream;

  Duration? get duration => _audioPlayer.duration;

  Duration get position => _audioPlayer.position;

  bool get isPlaying => _audioPlayer.playing;

  bool get hasAudioSource => _audioPlayer.audioSource != null;

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
      _remoteAudioSource = null;
      _localAudioPath = filePath;
      await _audioPlayer.setFilePath(filePath);
      debugPrint('Audio source set successfully: $filePath');
    } catch (error, stackTrace) {
      debugPrint('Failed to load audio file: $error');
      debugPrint('$stackTrace');
      throw Exception('所选文件不是可播放的音频，或当前格式不受支持');
    }
  }

  Future<void> loadAudioFromUrl(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      // ignore: experimental_member_use
      final audioSource = LockCachingAudioSource(
        Uri.parse(url),
        headers: headers,
      );
      _remoteAudioSource = audioSource;
      _localAudioPath = null;
      await _audioPlayer.setAudioSource(audioSource);
      debugPrint('Audio URL set successfully: $url');
    } catch (error, stackTrace) {
      debugPrint('Failed to load audio url: $error');
      debugPrint('$stackTrace');
      throw Exception('搜索到的伴奏音频暂时无法播放');
    }
  }

  Future<String?> prepareCurrentAudioForExport({
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (_localAudioPath != null) {
      return _localAudioPath;
    }

    final remoteAudioSource = _remoteAudioSource;
    if (remoteAudioSource == null) {
      return null;
    }

    final cacheFile = await remoteAudioSource.cacheFile;
    if (await cacheFile.exists()) {
      return cacheFile.path;
    }

    final completer = Completer<void>();
    late final StreamSubscription<double> subscription;
    subscription = remoteAudioSource.downloadProgressStream.listen((progress) {
      if (progress >= 1.0 && !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await completer.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }

    return await cacheFile.exists() ? cacheFile.path : null;
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
