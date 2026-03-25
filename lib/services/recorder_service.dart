import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class RecorderService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  bool _isInitialized = false;
  String? _recordingPath;

  bool get isRecording => _recorder.isRecording;

  Future<bool> init() async {
    if (_isInitialized) {
      return true;
    }

    final permissionsGranted = await _requestPermissions();
    if (!permissionsGranted) {
      debugPrint('Recorder permissions were not granted.');
      return false;
    }

    try {
      await _recorder.openRecorder();
      _isInitialized = true;
      debugPrint('Recorder service initialized.');
      return true;
    } catch (error) {
      debugPrint('Failed to initialize recorder service: $error');
      return false;
    }
  }

  Future<bool> _requestPermissions() async {
    if (kIsWeb) {
      return false;
    }

    final microphoneStatus = await Permission.microphone.request();
    if (microphoneStatus != PermissionStatus.granted) {
      debugPrint('Microphone permission was denied.');
      return false;
    }

    return true;
  }

  Future<bool> startRecording(String fileName) async {
    if (!await init()) {
      debugPrint('Recorder is not ready.');
      return false;
    }

    if (_recorder.isRecording) {
      debugPrint('Recorder is already recording.');
      return false;
    }

    try {
      final recordingsDir = await _resolveRecordingDirectory();
      if (recordingsDir == null) {
        debugPrint('Failed to resolve recording directory.');
        return false;
      }

      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      final safeFileName = _sanitizeFileName(fileName);
      _recordingPath = '${recordingsDir.path}/$safeFileName.wav';

      await _recorder.startRecorder(
        toFile: _recordingPath,
        codec: Codec.pcm16WAV,
      );
      debugPrint('Recording started: $_recordingPath');
      return true;
    } catch (error) {
      debugPrint('Failed to start recording: $error');
      _recordingPath = null;
      return false;
    }
  }

  Future<String?> stopRecording() async {
    if (!_recorder.isRecording) {
      debugPrint('Recorder is not currently recording.');
      return null;
    }

    try {
      await _recorder.stopRecorder();
      final path = _recordingPath;
      _recordingPath = null;
      debugPrint('Recording stopped. Saved to: $path');
      return path;
    } catch (error) {
      debugPrint('Failed to stop recording: $error');
      return null;
    }
  }

  Future<Directory?> _resolveRecordingDirectory() async {
    if (kIsWeb) {
      return null;
    }

    if (Platform.isAndroid) {
      final baseDir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      return Directory('${baseDir.path}/KaraokeRecordings');
    }

    final baseDir = await getApplicationDocumentsDirectory();
    return Directory('${baseDir.path}/KaraokeRecordings');
  }

  String _sanitizeFileName(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void dispose() {
    if (_isInitialized) {
      _recorder.closeRecorder();
      _isInitialized = false;
    }
  }
}
