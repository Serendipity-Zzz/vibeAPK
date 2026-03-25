import 'dart:io';

import 'package:ffmpeg_kit_flutter_minimal/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_minimal/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class RecorderService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  bool _isInitialized = false;
  String? _activeSegmentPath;
  int? _activeSegmentStartMs;
  String? _sessionName;
  final List<RecordedSegment> _segments = <RecordedSegment>[];

  bool get isRecording => _recorder.isRecording;

  bool get hasRecordedContent =>
      _segments.isNotEmpty || _activeSegmentPath != null;

  bool get supportsMixedExport =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux);

  Future<RecorderActionResult> init() async {
    if (_isInitialized) {
      return const RecorderActionResult.success();
    }

    final permissionsResult = await _ensureMicrophonePermission();
    if (!permissionsResult.success) {
      return permissionsResult;
    }

    try {
      await _recorder.openRecorder();
      _isInitialized = true;
      debugPrint('Recorder service initialized.');
      return const RecorderActionResult.success();
    } catch (error) {
      debugPrint('Failed to initialize recorder service: $error');
      return const RecorderActionResult.failure('录音器初始化失败');
    }
  }

  Future<RecorderActionResult> startSegment({
    required String sessionName,
    required int startOffsetMs,
  }) async {
    final initResult = await init();
    if (!initResult.success) {
      return initResult;
    }

    if (_recorder.isRecording) {
      return const RecorderActionResult.success();
    }

    if (_sessionName != null && _sessionName != sessionName) {
      await resetSession();
    }
    _sessionName = sessionName;

    try {
      final recordingsDir = await _resolveRecordingDirectory();
      if (recordingsDir == null) {
        return const RecorderActionResult.failure('无法创建录音目录');
      }

      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      final safeSessionName = _sanitizeFileName(sessionName);
      final fileName =
          '${safeSessionName}_${DateTime.now().millisecondsSinceEpoch}.wav';
      final segmentPath = '${recordingsDir.path}/$fileName';

      await _recorder.startRecorder(
        toFile: segmentPath,
        codec: Codec.pcm16WAV,
      );

      _activeSegmentPath = segmentPath;
      _activeSegmentStartMs = startOffsetMs;
      debugPrint(
        'Recording segment started at $startOffsetMs ms -> $segmentPath',
      );
      return const RecorderActionResult.success();
    } catch (error) {
      debugPrint('Failed to start recording: $error');
      _activeSegmentPath = null;
      _activeSegmentStartMs = null;
      return RecorderActionResult.failure('开始录音失败：$error');
    }
  }

  Future<RecorderActionResult> stopActiveSegment() async {
    if (!_recorder.isRecording) {
      return const RecorderActionResult.success();
    }

    try {
      await _recorder.stopRecorder();
      final path = _activeSegmentPath;
      final startOffsetMs = _activeSegmentStartMs;
      _activeSegmentPath = null;
      _activeSegmentStartMs = null;

      if (path != null && startOffsetMs != null) {
        _segments.add(
          RecordedSegment(
            filePath: path,
            startOffsetMs: startOffsetMs,
          ),
        );
      }

      return const RecorderActionResult.success();
    } catch (error) {
      debugPrint('Failed to stop recording: $error');
      return RecorderActionResult.failure('停止录音失败：$error');
    }
  }

  Future<void> resetSession() async {
    await stopActiveSegment();
    _sessionName = null;
    _segments.clear();
  }

  Future<RecorderExportResult> exportMixedTrack({
    required String exportBaseName,
    required String accompanimentPath,
    required Duration accompanimentDuration,
  }) async {
    final stopResult = await stopActiveSegment();
    if (!stopResult.success) {
      return RecorderExportResult.failure(stopResult.message!);
    }

    if (!supportsMixedExport) {
      return const RecorderExportResult.failure('当前平台暂不支持导出混音文件');
    }

    final exportDir = await _resolveExportDirectory();
    if (exportDir == null) {
      return const RecorderExportResult.failure('无法创建导出目录');
    }
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final safeName = _sanitizeFileName(exportBaseName);
    final outputPath = '${exportDir.path}/$safeName.m4a';
    final command = _buildExportCommand(
      accompanimentPath: accompanimentPath,
      accompanimentDuration: accompanimentDuration,
      outputPath: outputPath,
    );

    try {
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        debugPrint('FFmpeg export failed: $logs');
        return const RecorderExportResult.failure('导出混音失败');
      }

      return RecorderExportResult.success(
        outputPath,
        _segments.isEmpty ? '未检测到人声片段，已导出完整伴奏' : null,
      );
    } catch (error) {
      debugPrint('Failed to export mixed track: $error');
      return RecorderExportResult.failure('导出混音失败：$error');
    }
  }

  String _buildExportCommand({
    required String accompanimentPath,
    required Duration accompanimentDuration,
    required String outputPath,
  }) {
    final inputArgs = <String>[
      '-y',
      '-i',
      _quoteArg(accompanimentPath),
    ];

    if (_segments.isEmpty) {
      return [
        ...inputArgs,
        '-t',
        accompanimentDuration.inMilliseconds / 1000.0,
        '-c:a',
        'aac',
        '-b:a',
        '192k',
        _quoteArg(outputPath),
      ].join(' ');
    }

    final filterParts = <String>[];
    final mixInputs = <String>['[0:a]'];

    for (int index = 0; index < _segments.length; index++) {
      final segment = _segments[index];
      inputArgs
        ..add('-i')
        ..add(_quoteArg(segment.filePath));
      final label = 'v$index';
      filterParts.add(
        '[${index + 1}:a]adelay=${segment.startOffsetMs}|${segment.startOffsetMs},aresample=async=1[$label]',
      );
      mixInputs.add('[$label]');
    }

    filterParts.add(
      '${mixInputs.join()}amix=inputs=${mixInputs.length}:duration=first:dropout_transition=0[mix]',
    );

    final durationSeconds = accompanimentDuration.inMilliseconds / 1000.0;

    return [
      ...inputArgs,
      '-filter_complex',
      _quoteArg(filterParts.join(';')),
      '-map',
      _quoteArg('[mix]'),
      '-t',
      durationSeconds.toString(),
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      _quoteArg(outputPath),
    ].join(' ');
  }

  String _quoteArg(String value) {
    final escaped = value.replaceAll('"', r'\"');
    return '"$escaped"';
  }

  Future<RecorderActionResult> _ensureMicrophonePermission() async {
    if (kIsWeb) {
      return const RecorderActionResult.failure('Web 平台暂不支持录音');
    }

    final currentStatus = await Permission.microphone.status;
    if (currentStatus == PermissionStatus.granted) {
      return const RecorderActionResult.success();
    }

    final requestedStatus = await Permission.microphone.request();
    if (requestedStatus == PermissionStatus.granted) {
      return const RecorderActionResult.success();
    }

    if (requestedStatus == PermissionStatus.permanentlyDenied) {
      return const RecorderActionResult.failure(
        '麦克风权限已被永久拒绝，请到系统设置中手动开启',
      );
    }

    return const RecorderActionResult.failure('未获得麦克风权限');
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

  Future<Directory?> _resolveExportDirectory() async {
    if (kIsWeb) {
      return null;
    }

    if (Platform.isAndroid) {
      final baseDir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      return Directory('${baseDir.path}/KaraokeExports');
    }

    final baseDir = await getApplicationDocumentsDirectory();
    return Directory('${baseDir.path}/KaraokeExports');
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

class RecorderActionResult {
  const RecorderActionResult._({
    required this.success,
    this.message,
  });

  const RecorderActionResult.success() : this._(success: true);

  const RecorderActionResult.failure(String message)
      : this._(success: false, message: message);

  final bool success;
  final String? message;
}

class RecorderExportResult {
  const RecorderExportResult._({
    required this.success,
    this.filePath,
    this.message,
  });

  const RecorderExportResult.success(String filePath, [String? message])
      : this._(success: true, filePath: filePath, message: message);

  const RecorderExportResult.failure(String message)
      : this._(success: false, message: message);

  final bool success;
  final String? filePath;
  final String? message;
}

class RecordedSegment {
  const RecordedSegment({
    required this.filePath,
    required this.startOffsetMs,
  });

  final String filePath;
  final int startOffsetMs;
}
