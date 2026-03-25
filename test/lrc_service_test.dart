import 'package:flutter_test/flutter_test.dart';

import 'package:karaoke_app/services/lrc_service.dart';

void main() {
  final lrcService = LrcService();

  test('extracts Lyricsify candidate urls from html snippets', () {
    const searchHtml = '''
<ul>
  <li class="li">
    <a href="/lyrics/artist-name/song-name">
      <div>
        <strong>Song Name</strong>
        <small>Artist Name</small>
      </div>
    </a>
  </li>
</ul>
''';
    const detailHtml = '''
<div class="actions">
  <a href="/lrc/artist-name/song-name">Download LRC</a>
</div>
''';

    expect(
      lrcService.extractFirstLyricsPageUrl(searchHtml),
      'https://lyricsify.com/lyrics/artist-name/song-name',
    );
    expect(
      lrcService.extractLrcDownloadUrl(
        detailHtml,
        currentUrl: 'https://www.lyricsify.com/lyrics/artist-name/song-name',
      ),
      'https://www.lyricsify.com/lrc/artist-name/song-name',
    );
  });

  test('parses LRC timestamps with or without millisecond precision', () {
    const lrc = '''
[ti:Song Name]
[ar:Artist Name]
[00:01]Intro
[00:02.50]Verse
[00:03.500]Hook
''';

    final lyrics = lrcService.parseLrc(lrc);

    expect(lyrics, hasLength(3));
    expect(lyrics[0].timestamp, 1000);
    expect(lyrics[0].text, 'Intro');
    expect(lyrics[1].timestamp, 2500);
    expect(lyrics[2].timestamp, 3500);
  });
}
