import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../models/lyric_line.dart';
import '../services/audio_player_service.dart';
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

  String? _songIdentifier;
  List<LyricLine> _lyrics = [];
  int _currentLyricIndex = -1;
  int _lyricOffsetMs = 0;
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    _recorderService.init();
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

  @override
  void dispose() {
    _audioPlayerService.dispose();
    _lyricScrollService.dispose();
    _recorderService.dispose();
    _songController.dispose();
    super.dispose();
  }

  Future<void> _importAudio() async {
    debugPrint('Import button pressed.');

    try {
      final path = await _audioPlayerService.pickAndLoadAudio();
      if (!mounted) {
        return;
      }

      if (path == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未选择伴奏文件')));
        return;
      }

      final fileName = path.split(RegExp(r'[\\/]')).last;
      final extensionIndex = fileName.lastIndexOf('.');
      final songIdentifier =
          extensionIndex > 0 ? fileName.substring(0, extensionIndex) : fileName;

      setState(() => _songIdentifier = songIdentifier);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入伴奏：$songIdentifier')));
    } catch (error) {
      debugPrint('Failed to import audio: $error');
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入伴奏失败：$error')));
    }
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

  Future<void> _searchAndLoadLrc() async {
    final messenger = ScaffoldMessenger.of(context);
    final songName = _songController.text.trim().isEmpty
        ? (_songIdentifier ?? '')
        : _songController.text.trim();
    if (songName.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请输入歌曲名后再搜索歌词')),
      );
      return;
    }

    final lrcUrl = await _lrcService.searchLrc(songName, 'any');
    if (lrcUrl == null) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('未在歌词易找到可用的 LRC 歌词')),
        );
      }
      return;
    }

    final lrcPath = await _lrcService.downloadAndSaveLrc(lrcUrl, songName);
    if (lrcPath == null) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('歌词下载失败，或该页面没有可用时间轴')),
        );
      }
      return;
    }

    final lyrics = await _lrcService.loadLrcFromFile(lrcPath);
    final offset = await _lyricScrollService.loadLyricOffset(songName);
    if (!mounted) {
      return;
    }

    setState(() {
      _lyrics = lyrics;
      _lyricOffsetMs = offset;
      _songIdentifier = songName;
    });
    _lyricScrollService.applyOffset(_lyrics, _lyricOffsetMs);
    messenger.showSnackBar(
      SnackBar(content: Text('已导入歌词：$songName')),
    );
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
                children: [
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
                    children: [
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
        actions: [
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
          children: [
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
      child: Row(
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.music_note),
            label: const Text('导入伴奏'),
            onPressed: _importAudio,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _songController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '搜索歌词',
                hintStyle: TextStyle(color: Colors.grey[400]),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search, color: Colors.white),
                  onPressed: _searchAndLoadLrc,
                ),
              ),
            ),
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
                '请先导入伴奏并搜索歌词',
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
        children: [
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

                  return Slider(
                    min: 0.0,
                    max: duration.inMilliseconds.toDouble(),
                    value: position.inMilliseconds.toDouble(),
                    onChanged: (value) {
                      _audioPlayerService.seek(
                        Duration(milliseconds: value.round()),
                      );
                    },
                    activeColor: Colors.white,
                    inactiveColor: Colors.grey[700],
                  );
                },
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.mic, color: Colors.white),
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
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      if (playing) {
                        await _audioPlayerService.pause();
                        final path = await _recorderService.stopRecording();
                        if (path != null && mounted) {
                          messenger.showSnackBar(
                            SnackBar(content: Text('录音已保存: $path')),
                          );
                        }
                        if (mounted) {
                          setState(() => _isRecording = false);
                        }
                      } else {
                        await _audioPlayerService.play();
                        if (_songIdentifier != null) {
                          final recordingStarted =
                              await _recorderService.startRecording(
                            _songIdentifier!,
                          );
                          if (mounted) {
                            setState(() => _isRecording = recordingStarted);
                          }
                          if (!recordingStarted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('录音未启动，请检查麦克风权限和保存目录'),
                              ),
                            );
                          }
                        }
                      }
                    },
                  );
                },
              ),
              StreamBuilder<double>(
                stream: _audioPlayerService.audioPlayer.volumeStream,
                builder: (context, snapshot) {
                  return PopupMenuButton<double>(
                    icon: const Icon(Icons.volume_up, color: Colors.white),
                    onSelected: _audioPlayerService.setVolume,
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 0.0, child: Text('静音')),
                      PopupMenuItem(value: 0.5, child: Text('50%')),
                      PopupMenuItem(value: 1.0, child: Text('100%')),
                    ],
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
