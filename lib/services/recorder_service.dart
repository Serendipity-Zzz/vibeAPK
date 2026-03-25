
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 录音服务类，封装了录音、权限处理和文件保存的逻辑。
class RecorderService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _isInitialized = false;
  String? _recordingPath;

  /// 获取录音器是否正在录制。
  bool get isRecording => _recorder.isRecording;

  /// 初始化录音服务，包括请求权限和打开音频会话。
  /// 
  /// 返回 true 表示初始化成功，否则失败。
  Future<bool> init() async {
    if (_isInitialized) return true;

    // 申请录音和存储权限
    final permissionsGranted = await _requestPermissions();
    if (!permissionsGranted) {
      debugPrint("录音或存储所需权限不足");
      return false;
    }

    try {
      await _recorder.openRecorder();
      _isInitialized = true;
      debugPrint("录音服务初始化成功");
      return true;
    } catch (e) {
      debugPrint("录音服务初始化失败: $e");
      return false;
    }
  }

  /// 动态申请麦克风和存储权限。
  Future<bool> _requestPermissions() async {
    // 1. 请求麦克风权限
    final microphoneStatus = await Permission.microphone.request();
    if (microphoneStatus != PermissionStatus.granted) {
      debugPrint("麦克风权限被拒绝");
      return false;
    }

    // 2. 请求存储权限，用于将录音文件保存到公共目录
    final storageStatus = await Permission.storage.request();
    if (storageStatus != PermissionStatus.granted) {
      debugPrint("存储权限被拒绝，无法保存录音文件");
      return false; // 强制要求存储权限
    }

    return true;
  }

  /// 开始录制。
  /// 
  /// [fileName] 保存的录音文件名（不含扩展名）。
  Future<void> startRecording(String fileName) async {
    if (!_isInitialized) {
      debugPrint("录音服务未初始化或权限不足");
      return;
    }
    if (_recorder.isRecording) {
      debugPrint("已经在录制中");
      return;
    }

    try {
      // 获取外部公共存储目录
      final directory = await getExternalStorageDirectory();
      if (directory == null) {
        debugPrint("无法获取外部存储目录");
        return;
      }
      
      // 在外部存储中创建一个专门的文件夹来存放录音
      final recordingsDir = Directory('${directory.path}/KaraokeRecordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      // 定义录音文件的完整路径
      _recordingPath = '${recordingsDir.path}/$fileName.wav';
      
      await _recorder.startRecorder(
        toFile: _recordingPath,
        codec: Codec.pcm16WAV, // 使用 WAV 格式
      );
      debugPrint("开始录制，文件将保存至: $_recordingPath");
    } catch (e) {
      debugPrint("开始录制失败: $e");
    }
  }

  /// 停止录制。
  /// 
  /// 返回录音文件的路径，如果录制未开始或失败则返回 null。
  Future<String?> stopRecording() async {
    if (!_recorder.isRecording) {
      debugPrint("当前没有正在进行的录制");
      return null;
    }

    try {
      await _recorder.stopRecorder();
      debugPrint("录制结束，文件保存在: $_recordingPath");
      final path = _recordingPath;
      _recordingPath = null; // 重置路径
      return path;
    } catch (e) {
      debugPrint("停止录制失败: $e");
      return null;
    }
  }

  /// 释放资源。
  void dispose() {
    if (_isInitialized) {
      _recorder.closeRecorder();
      _isInitialized = false;
    }
  }
}
