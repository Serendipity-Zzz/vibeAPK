import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

  bool get supportsMixedExport => !kIsWeb;

  Future<RecorderActionResult> init() async {
    if (_isInitialized) {
      return const RecorderActionResult.success();
    }

    final permissionResult = await _ensureMicrophonePermission();
    if (!permissionResult.success) {
      return permissionResult;
    }

    try {
      await _recorder.openRecorder();
      _isInitialized = true;
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
          RecordedSegment(filePath: path, startOffsetMs: startOffsetMs),
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

    if (!_isWavFile(accompanimentPath)) {
      return const RecorderExportResult.failure(
        '当前桌面端仅支持导出 WAV 伴奏。请重新导入 WAV 格式伴奏后再导出。',
      );
    }

    final exportDir = await _resolveExportDirectory();
    if (exportDir == null) {
      return const RecorderExportResult.failure('无法创建导出目录');
    }
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final safeName = _sanitizeFileName(exportBaseName);
    final outputPath = '${exportDir.path}/$safeName.wav';

    try {
      final accompanimentData = await _readWavFile(accompanimentPath);
      final expectedSamples = math.min(
        accompanimentData.samples.length,
        ((accompanimentDuration.inMicroseconds *
                    accompanimentData.sampleRate) ~/
                1000000) *
            accompanimentData.channels,
      );
      final mixedSamples = Int16List.fromList(
        accompanimentData.samples.take(expectedSamples).toList(),
      );

      for (final segment in _segments) {
        final segmentFile = File(segment.filePath);
        if (!await segmentFile.exists() || !_isWavFile(segment.filePath)) {
          continue;
        }

        final segmentData = await _readWavFile(segment.filePath);
        _mixSegment(
          targetSamples: mixedSamples,
          sourceSamples: segmentData.samples,
          startOffsetMs: segment.startOffsetMs,
          sampleRate: accompanimentData.sampleRate,
          channels: accompanimentData.channels,
        );
      }

      await _writeWavFile(
        outputPath: outputPath,
        sampleRate: accompanimentData.sampleRate,
        channels: accompanimentData.channels,
        bitDepth: accompanimentData.bitDepth,
        samples: mixedSamples,
      );

      return RecorderExportResult.success(
        outputPath,
        _segments.isEmpty ? '未检测到人声片段，已导出完整伴奏' : null,
      );
    } catch (error) {
      debugPrint('Failed to export mixed track: $error');
      return RecorderExportResult.failure('导出混音失败：$error');
    }
  }

  Future<_WavFileData> _readWavFile(String path) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 44) {
      throw Exception('WAV 文件长度不合法');
    }

    final byteData = bytes.buffer.asByteData();
    if (_chunkId(byteData, 0) != 'RIFF' || _chunkId(byteData, 8) != 'WAVE') {
      throw Exception('音频文件不是有效的 WAV');
    }

    int channels = 0;
    int sampleRate = 0;
    int bitDepth = 0;
    int? dataOffset;
    int? dataSize;
    int offset = 12;

    while (offset + 8 <= bytes.length) {
      final chunkId = _chunkId(byteData, offset);
      final chunkSize = byteData.getUint32(offset + 4, Endian.little);
      final chunkDataOffset = offset + 8;

      if (chunkId == 'fmt ') {
        final format = byteData.getUint16(chunkDataOffset, Endian.little);
        if (format != 1) {
          throw Exception('仅支持 PCM WAV 文件');
        }
        channels = byteData.getUint16(chunkDataOffset + 2, Endian.little);
        sampleRate = byteData.getUint32(chunkDataOffset + 4, Endian.little);
        bitDepth = byteData.getUint16(chunkDataOffset + 14, Endian.little);
      } else if (chunkId == 'data') {
        dataOffset = chunkDataOffset;
        dataSize = chunkSize;
        break;
      }

      offset = chunkDataOffset + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (channels <= 0 || sampleRate <= 0 || bitDepth != 16) {
      throw Exception('WAV 参数无法解析或格式不受支持');
    }
    if (dataOffset == null || dataSize == null) {
      throw Exception('WAV 缺少 PCM 数据块');
    }

    final sampleCount = dataSize ~/ 2;
    final samples = Int16List(sampleCount);
    final pcmData = bytes.buffer.asByteData(dataOffset, dataSize);
    for (int index = 0; index < sampleCount; index++) {
      samples[index] = pcmData.getInt16(index * 2, Endian.little);
    }

    return _WavFileData(
      sampleRate: sampleRate,
      channels: channels,
      bitDepth: bitDepth,
      samples: samples,
    );
  }

  Future<void> _writeWavFile({
    required String outputPath,
    required int sampleRate,
    required int channels,
    required int bitDepth,
    required Int16List samples,
  }) async {
    if (bitDepth != 16) {
      throw Exception('暂时仅支持 16-bit WAV 导出');
    }

    final dataSize = samples.length * 2;
    final bytes = Uint8List(44 + dataSize);
    final byteData = ByteData.sublistView(bytes);

    _writeChunkId(byteData, 0, 'RIFF');
    byteData.setUint32(4, 36 + dataSize, Endian.little);
    _writeChunkId(byteData, 8, 'WAVE');
    _writeChunkId(byteData, 12, 'fmt ');
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little);
    byteData.setUint16(22, channels, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    final blockAlign = channels * (bitDepth ~/ 8);
    byteData.setUint32(28, sampleRate * blockAlign, Endian.little);
    byteData.setUint16(32, blockAlign, Endian.little);
    byteData.setUint16(34, bitDepth, Endian.little);
    _writeChunkId(byteData, 36, 'data');
    byteData.setUint32(40, dataSize, Endian.little);

    for (int index = 0; index < samples.length; index++) {
      byteData.setInt16(44 + (index * 2), samples[index], Endian.little);
    }

    await File(outputPath).writeAsBytes(bytes, flush: true);
  }

  void _mixSegment({
    required Int16List targetSamples,
    required Int16List sourceSamples,
    required int startOffsetMs,
    required int sampleRate,
    required int channels,
  }) {
    final startFrame = ((startOffsetMs * sampleRate) / 1000).round();
    final startSampleIndex = startFrame * channels;

    for (int index = 0; index < sourceSamples.length; index++) {
      final targetIndex = startSampleIndex + index;
      if (targetIndex >= targetSamples.length) {
        break;
      }

      final mixed = targetSamples[targetIndex] + sourceSamples[index];
      targetSamples[targetIndex] = mixed.clamp(-32768, 32767).toInt();
    }
  }

  bool _isWavFile(String path) {
    final lowerPath = path.toLowerCase();
    return lowerPath.endsWith('.wav') || lowerPath.endsWith('.wave');
  }

  String _chunkId(ByteData data, int offset) {
    return String.fromCharCodes(
      List<int>.generate(4, (index) => data.getUint8(offset + index)),
    );
  }

  void _writeChunkId(ByteData data, int offset, String value) {
    for (int index = 0; index < 4; index++) {
      data.setUint8(offset + index, value.codeUnitAt(index));
    }
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

class _WavFileData {
  const _WavFileData({
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.samples,
  });

  final int sampleRate;
  final int channels;
  final int bitDepth;
  final Int16List samples;
}
