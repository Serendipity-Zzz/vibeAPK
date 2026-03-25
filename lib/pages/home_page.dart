import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../models/lyric_line.dart';
import '../services/audio_player_service.dart';
import '../services/gequhai_service.dart';
import '../services/lrc_service.dart';
import '../services/lyric_scroll_service.dart';
import '../services/recorder_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  final LrcService _lrcService = LrcService();
  final LyricScrollService _lyricScrollService = LyricScrollService();
  final RecorderService _recorderService = RecorderService();
  final TextEditingController _songController = TextEditingController();

  late final GequhaiService _gequhaiService =
      GequhaiService(lrcService: _lrcService);

  String? _songIdentifier;
  List<LyricLine> _lyrics = <LyricLine>[];
  int _currentLyricIndex = -1;
  int _lyricOffsetMs = 0;
  bool _isRecording = false;
  bool _isSearching = false;
  double? _dragSliderValue;

  @override
  void initState() {
    super.initState();
    _initializeRecorder();
    _audioPlayerService.positionStream.listen((position) {
      if (_lyrics.isEmpty) {
        return;
      }

      final newIndex = _findCurrentLyricIndex(position.inMilliseconds);
      if (newIndex != _currentLyricIndex && mounted) {
        setState(() => _currentLyricIndex = newIndex);
        _lyricScrollService.scrollTo(newIndex, 60.0);
      }
    });
  }

  Future<void> _initializeRecorder() async {
    final result = await _recorderService.init();
    if (!result.success && mounted) {
      _showMessage(result.message!);
    }
  }

  @override
  void dispose() {
    _audioPlayerService.dispose();
    _lyricScrollService.dispose();
    _recorderService.dispose();
    _songController.dispose();
    super.dispose();
  }

  Future<void> _importAudio() async {
    try {
      final path = await _audioPlayerService.pickAndLoadAudio();
      if (!mounted) {
        return;
      }

      if (path == null) {
        _showMessage('未选择伴奏文件');
        return;
      }

      final songIdentifier = _fileNameWithoutExtension(path);
      await _switchToNewAccompaniment(songIdentifier);
      _showMessage('已导入本地伴奏：$songIdentifier');
    } catch (error) {
      if (mounted) {
        _showMessage('导入伴奏失败：$error');
      }
    }
  }

  Future<void> _importLrcFromLocal() async {
    try {
      final path = await _lrcService.pickLrcFile();
      if (path == null) {
        if (mounted) {
          _showMessage('未选择歌词文件');
        }
        return;
      }

      final fallbackName = _songIdentifier ?? _currentSearchKeyword();
      final songName = fallbackName.isNotEmpty
          ? fallbackName
          : _fileNameWithoutExtension(path);
      await _loadLyricsFromFile(songName, path);
    } catch (error) {
      if (mounted) {
        _showMessage('导入本地歌词失败：$error');
      }
    }
  }

  Future<void> _searchAndImportAudio() async {
    final detail = await _searchSongDetail();
    if (detail == null) {
      return;
    }

    try {
      final audioSource = await _gequhaiService.resolveAudioSource(detail);
      if (audioSource == null) {
        _showMessage('未获取到可导入的伴奏音频');
        return;
      }

      await _audioPlayerService.loadAudioFromUrl(
        audioSource.audioUrl,
        headers: audioSource.headers,
      );
      if (!mounted) {
        return;
      }

      await _switchToNewAccompaniment(detail.songIdentifier);
      final qualityText = audioSource.usedHighQuality ? '高品质' : '标准音质';
      final warning = audioSource.warningMessage;
      _showMessage(
        warning == null
            ? '已搜索导入$qualityText伴奏：${detail.songIdentifier}'
            : '已导入伴奏：${detail.songIdentifier}；$warning',
      );
    } catch (error) {
      if (mounted) {
        _showMessage('搜索导入伴奏失败：$error');
      }
    }
  }

  Future<void> _searchAndLoadLrc() async {
    final detail = await _searchSongDetail();
    if (detail == null) {
      return;
    }

    try {
      final lrcPath = await _gequhaiService.downloadAndSaveLrc(
        detail,
        fileName: detail.songIdentifier,
      );
      if (lrcPath == null) {
        _showMessage('未找到可导入的 LRC 歌词');
        return;
      }

      await _loadLyricsFromFile(detail.songIdentifier, lrcPath);
    } catch (error) {
      if (mounted) {
        _showMessage('搜索导入歌词失败：$error');
      }
    }
  }

  Future<void> _exportMixedAudio() async {
    if (!_audioPlayerService.hasAudioSource || _songIdentifier == null) {
      _showMessage('请先导入伴奏后再导出');
      return;
    }

    if (_audioPlayerService.isPlaying) {
      await _audioPlayerService.pause();
    }

    final stopResult = await _recorderService.stopActiveSegment();
    if (!stopResult.success) {
      _showMessage(stopResult.message!);
      return;
    }

    setState(() => _isRecording = false);

    final accompanimentPath = await _audioPlayerService.prepareCurrentAudioForExport();
    if (accompanimentPath == null) {
      _showMessage('当前伴奏尚未准备好导出，请稍后再试');
      return;
    }

    final duration = _audioPlayerService.duration;
    if (duration == null) {
      _showMessage('当前伴奏时长未知，暂时无法导出');
      return;
    }

    final result = await _recorderService.exportMixedTrack(
      exportBaseName: _songIdentifier!,
      accompanimentPath: accompanimentPath,
      accompanimentDuration: duration,
    );

    if (!mounted) {
      return;
    }

    if (!result.success) {
      _showMessage(result.message!);
      return;
    }

    if (result.message != null) {
      _showMessage('${result.message}：${result.filePath}');
    } else {
      _showMessage('混音导出完成：${result.filePath}');
    }
  }

  Future<void> _togglePlayback() async {
    if (!_audioPlayerService.hasAudioSource) {
      _showMessage('请先导入伴奏');
      return;
    }

    if (_audioPlayerService.isPlaying) {
      await _audioPlayerService.pause();
      final stopResult = await _recorderService.stopActiveSegment();
      if (!stopResult.success && mounted) {
        _showMessage(stopResult.message!);
      }
      if (mounted) {
        setState(() => _isRecording = false);
      }
      return;
    }

    if (_songIdentifier != null) {
      final startResult = await _recorderService.startSegment(
        sessionName: _songIdentifier!,
        startOffsetMs: _audioPlayerService.position.inMilliseconds,
      );
      if (!startResult.success) {
        if (mounted) {
          _showMessage(startResult.message!);
        }
        return;
      }
    }

    await _audioPlayerService.play();
    if (mounted) {
      setState(() => _isRecording = _songIdentifier != null);
    }
  }

  Future<void> _handleSeekEnd(double value) async {
    final target = Duration(milliseconds: value.round());
    final wasPlaying = _audioPlayerService.isPlaying;

    if (wasPlaying) {
      await _audioPlayerService.pause();
      final stopResult = await _recorderService.stopActiveSegment();
      if (!stopResult.success && mounted) {
        _showMessage(stopResult.message!);
      }
    }

    await _audioPlayerService.seek(target);
    if (!mounted) {
      return;
    }

    setState(() {
      _dragSliderValue = null;
      _isRecording = false;
    });

    if (wasPlaying && _songIdentifier != null) {
      final startResult = await _recorderService.startSegment(
        sessionName: _songIdentifier!,
        startOffsetMs: target.inMilliseconds,
      );
      if (!startResult.success) {
        if (mounted) {
          _showMessage(startResult.message!);
        }
        return;
      }

      await _audioPlayerService.play();
      if (mounted) {
        setState(() => _isRecording = true);
      }
    }
  }

  Future<void> _switchToNewAccompaniment(String songIdentifier) async {
    await _audioPlayerService.stop();
    await _recorderService.resetSession();
    if (!mounted) {
      return;
    }

    setState(() {
      _songIdentifier = songIdentifier;
      _isRecording = false;
      _dragSliderValue = null;
      _currentLyricIndex = -1;
    });
  }

  Future<GequhaiSongDetail?> _searchSongDetail() async {
    final songName = _currentSearchKeyword();
    if (songName.isEmpty) {
      _showMessage('请输入歌曲名后再搜索');
      return null;
    }

    setState(() => _isSearching = true);
    try {
      final detail = await _gequhaiService.searchSong(songName, 'any');
      if (detail == null) {
        if (mounted) {
          _showMessage('未在歌曲海找到匹配的歌曲');
        }
        return null;
      }
      return detail;
    } catch (error) {
      if (mounted) {
        _showMessage('搜索歌曲失败：$error');
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _loadLyricsFromFile(String songName, String lrcPath) async {
    final lyrics = await _lrcService.loadLrcFromFile(lrcPath);
    if (lyrics.isEmpty) {
      if (mounted) {
        _showMessage('歌词文件已导入，但没有解析出时间轴内容');
      }
      return;
    }

    final offset = await _lyricScrollService.loadLyricOffset(songName);
    if (!mounted) {
      return;
    }

    setState(() {
      _lyrics = lyrics;
      _lyricOffsetMs = offset;
      _songIdentifier = songName;
      _currentLyricIndex = -1;
    });
    _lyricScrollService.applyOffset(_lyrics, _lyricOffsetMs);
    _showMessage('已导入歌词：$songName');
  }

  String _currentSearchKeyword() {
    final text = _songController.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
    return _songIdentifier ?? '';
  }

  String _fileNameWithoutExtension(String path) {
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final extensionIndex = fileName.lastIndexOf('.');
    return extensionIndex > 0 ? fileName.substring(0, extensionIndex) : fileName;
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  int _findCurrentLyricIndex(int milliseconds) {
    for (int i = 0; i < _lyrics.length; i++) {
      if (milliseconds >= _lyrics[i].timestamp) {
        if (i + 1 >= _lyrics.length ||
            milliseconds < _lyrics[i + 1].timestamp) {
          return i;
        }
      }
    }
    return -1;
  }

  void _showAlignmentDialog() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Container(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '歌词对齐',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text('偏移量: ${(_lyricOffsetMs / 1000).toStringAsFixed(2)} s'),
                  Slider(
                    min: -10000,
                    max: 10000,
                    divisions: 400,
                    label: '${(_lyricOffsetMs / 1000).toStringAsFixed(2)}s',
                    value: _lyricOffsetMs.toDouble(),
                    onChanged: (value) {
                      setModalState(() => _lyricOffsetMs = value.round());
                      _lyricScrollService.applyOffset(_lyrics, _lyricOffsetMs);
                      setState(() {});
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: <Widget>[
                      ElevatedButton(
                        onPressed: _audioPlayerService.play,
                        child: const Text('播放预览'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (_songIdentifier != null) {
                            _lyricScrollService.saveLyricOffset(
                              _songIdentifier!,
                              _lyricOffsetMs,
                            );
                          }
                          Navigator.pop(context);
                        },
                        child: const Text('确认保存'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('K 歌伴唱'),
        backgroundColor: Colors.grey[850],
        elevation: 0,
        actions: <Widget>[
          if (_isRecording)
            const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: Icon(Icons.mic, color: Colors.red),
            ),
        ],
      ),
      backgroundColor: Colors.grey[900],
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: <Widget>[
            _buildTopControls(),
            _buildLyricView(),
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _songController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '输入歌名或 歌名 歌手',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    helperText: '搜索源：歌曲海（Gequhai）',
                    helperStyle: TextStyle(color: Colors.grey[500]),
                    suffixIcon: _isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.search, color: Colors.white),
                            onPressed: _searchAndLoadLrc,
                          ),
                  ),
                  onSubmitted: (_) => _searchAndLoadLrc(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              ElevatedButton.icon(
                icon: const Icon(Icons.library_music),
                label: const Text('本地导入伴奏'),
                onPressed: _importAudio,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.cloud_download),
                label: const Text('搜索导入伴奏'),
                onPressed: _isSearching ? null : _searchAndImportAudio,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.lyrics),
                label: const Text('搜索导入歌词'),
                onPressed: _isSearching ? null : _searchAndLoadLrc,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text('本地导入 LRC'),
                onPressed: _importLrcFromLocal,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLyricView() {
    return Expanded(
      child: _lyrics.isEmpty
          ? Center(
              child: Text(
                '请先导入伴奏并导入歌词',
                style: TextStyle(color: Colors.grey[400]),
              ),
            )
          : ListView.builder(
              controller: _lyricScrollService.scrollController,
              itemCount: _lyrics.length,
              itemBuilder: (context, index) {
                final isCurrent = _currentLyricIndex == index;
                return Container(
                  height: 60.0,
                  alignment: Alignment.center,
                  child: Text(
                    _lyrics[index].text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isCurrent ? 20 : 16,
                      color: isCurrent ? Colors.white : Colors.grey[600],
                      fontWeight:
                          isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20.0, top: 10.0),
      child: Column(
        children: <Widget>[
          StreamBuilder<Duration?>(
            stream: _audioPlayerService.durationStream,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: _audioPlayerService.positionStream,
                builder: (context, positionSnapshot) {
                  var position = positionSnapshot.data ?? Duration.zero;
                  if (position > duration) {
                    position = duration;
                  }

                  final sliderValue =
                      _dragSliderValue ?? position.inMilliseconds.toDouble();
                  return Slider(
                    min: 0.0,
                    max: duration.inMilliseconds.toDouble(),
                    value: duration.inMilliseconds == 0
                        ? 0.0
                        : sliderValue.clamp(
                            0.0,
                            duration.inMilliseconds.toDouble(),
                          ),
                    onChanged: (value) {
                      setState(() => _dragSliderValue = value);
                    },
                    onChangeEnd: _handleSeekEnd,
                    activeColor: Colors.white,
                    inactiveColor: Colors.grey[700],
                  );
                },
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.tune, color: Colors.white),
                onPressed: _showAlignmentDialog,
                tooltip: '歌词对齐',
              ),
              StreamBuilder<PlayerState>(
                stream: _audioPlayerService.playerStateStream,
                builder: (context, snapshot) {
                  final playerState = snapshot.data;
                  final playing = playerState?.playing ?? false;
                  return IconButton(
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      color: Colors.white,
                    ),
                    iconSize: 64.0,
                    onPressed: _togglePlayback,
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.save_alt, color: Colors.white),
                iconSize: 36,
                onPressed: _exportMixedAudio,
                tooltip: '导出混音',
              ),
              PopupMenuButton<double>(
                icon: const Icon(Icons.volume_up, color: Colors.white),
                onSelected: _audioPlayerService.setVolume,
                itemBuilder: (context) => const <PopupMenuEntry<double>>[
                  PopupMenuItem(value: 0.0, child: Text('静音')),
                  PopupMenuItem(value: 0.5, child: Text('50%')),
                  PopupMenuItem(value: 1.0, child: Text('100%')),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
