import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/lrc_service.dart';

class LyricsifyVerificationDialog extends StatefulWidget {
  const LyricsifyVerificationDialog({
    super.key,
    required this.lrcService,
    required this.songName,
    required this.initialUrl,
  });

  final LrcService lrcService;
  final String songName;
  final String initialUrl;

  @override
  State<LyricsifyVerificationDialog> createState() =>
      _LyricsifyVerificationDialogState();
}

class _LyricsifyVerificationDialogState
    extends State<LyricsifyVerificationDialog> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  String _currentUrl = '';
  String _currentTitle = 'Lyricsify 验证导入';
  String? _errorText;
  bool _initializing = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  Future<void> _initializeWebView() async {
    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(Colors.white);
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      _subscriptions.add(
        _controller.url.listen((url) {
          if (!mounted) {
            return;
          }
          setState(() => _currentUrl = url);
        }),
      );
      _subscriptions.add(
        _controller.title.listen((title) {
          if (!mounted) {
            return;
          }
          setState(() => _currentTitle = title);
        }),
      );

      await _controller.loadUrl(widget.initialUrl);
      if (!mounted) {
        return;
      }
      setState(() => _initializing = false);
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _initializing = false;
        _errorText =
            'WebView 初始化失败（${error.code}）：${error.message ?? '未知错误'}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _initializing = false;
        _errorText = 'WebView 初始化失败：$error';
      });
    }
  }

  Future<void> _importFromCurrentPage() async {
    if (_importing || !_controller.value.isInitialized) {
      return;
    }

    setState(() {
      _importing = true;
      _errorText = null;
    });

    try {
      final snapshot = await _controller.executeScript('''
(() => ({
  href: window.location.href || '',
  title: document.title || '',
  html: document.documentElement ? document.documentElement.outerHTML : '',
  text: document.body ? document.body.innerText : ''
}))();
''');

      final data = snapshot is Map ? Map<String, dynamic>.from(snapshot) : null;
      if (data == null) {
        throw const FormatException('页面数据读取失败');
      }

      final pageUrl = (data['href'] as String? ?? '').trim();
      final pageTitle = (data['title'] as String? ?? '').trim();
      final html = (data['html'] as String? ?? '').trim();
      final pageText = data['text'] as String? ?? '';

      final lrcPath = await widget.lrcService.saveLrcFromPageHtml(
        html: html,
        fileName: widget.songName,
        pageUrl: pageUrl,
        pageTitle: pageTitle,
        pageText: pageText,
      );
      if (lrcPath != null) {
        if (mounted) {
          Navigator.of(context).pop(lrcPath);
        }
        return;
      }

      final nextLyricsUrl = widget.lrcService.extractFirstLyricsPageUrl(
        html,
        currentUrl: pageUrl,
      );
      if (nextLyricsUrl != null && nextLyricsUrl != pageUrl) {
        await _controller.loadUrl(nextLyricsUrl);
        if (mounted) {
          setState(() {
            _errorText = '当前页是搜索结果，已自动打开首个歌词页，请确认内容后再次点击导入。';
          });
        }
        return;
      }

      final lrcDownloadUrl = widget.lrcService.extractLrcDownloadUrl(
        html,
        currentUrl: pageUrl,
      );
      if (lrcDownloadUrl != null && lrcDownloadUrl != pageUrl) {
        await _controller.loadUrl(lrcDownloadUrl);
        if (mounted) {
          setState(() {
            _errorText = '当前页只识别到 LRC 下载链接，已自动跳转，请再次点击导入。';
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _errorText = '没有识别到带时间轴的歌词，请先完成验证并打开具体歌词页。';
        });
      }
    } on LyricsFetchException catch (error) {
      if (mounted) {
        setState(() => _errorText = error.message);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _errorText = '导入失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: SizedBox(
        width: 1080,
        height: 760,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _currentTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '如果 Lyricsify 触发人机验证，请在此窗口内完成验证并打开目标歌词页，然后点击“导入当前页面”。',
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _currentUrl.isEmpty ? widget.initialUrl : _currentUrl,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_errorText != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: _buildWebView(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  TextButton.icon(
                    onPressed: _controller.value.isInitialized
                        ? _controller.reload
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新'),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _importing ? null : _importFromCurrentPage,
                    icon: _importing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: const Text('导入当前页面'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebView() {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorText != null && !_controller.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorText!,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Stack(
      children: <Widget>[
        Webview(_controller),
        StreamBuilder<LoadingState>(
          stream: _controller.loadingState,
          builder: (context, snapshot) {
            if (snapshot.data == LoadingState.loading) {
              return const LinearProgressIndicator(minHeight: 2);
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }
}
