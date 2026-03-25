import 'package:flutter_test/flutter_test.dart';

import 'package:karaoke_app/services/gequhai_service.dart';
import 'package:karaoke_app/services/lrc_service.dart';

void main() {
  final lrcService = LrcService();
  final gequhaiService = GequhaiService(lrcService: lrcService);

  test('parses Gequhai search results and detail blocks', () {
    const searchHtml = '''
<tbody>
  <tr>
    <td>1</td>
    <td><a href="/play/556" class="text-info font-weight-bold">夜曲</a></td>
    <td style="color: #666;font-size: 15px;">周杰伦</td>
  </tr>
</tbody>
''';
    const detailHtml = '''
<div class="content-lrc mt-1" id="content-lrc2">[00:00.00]夜曲 - 周杰伦<br />
[00:01.00]一群嗜血的蚂蚁 被腐肉所吸引<br /></div>
<script type="text/javascript">
window.mp3_id = '556';
window.play_id = 'TjSQyVfF';
window.mp3_title = '夜曲';
window.mp3_author = '周杰伦';
window.mp3_extra_url = 'a#R0c#M6Ly9wYW4ucXVhcmsuY24vcy8yMjI3N2Q0MTJmNzM=';
</script>
''';

    final results = gequhaiService.parseSearchResults(searchHtml, query: '夜曲');
    expect(results, hasLength(1));
    expect(results.first.pageUrl, 'https://www.gequhai.com/play/556');
    expect(results.first.title, '夜曲');
    expect(results.first.artist, '周杰伦');

    final detail = gequhaiService.parseSongDetailHtml(
      detailHtml,
      pageUrl: 'https://www.gequhai.com/play/556',
    );
    expect(detail, isNotNull);
    expect(detail!.playId, 'TjSQyVfF');
    expect(detail.highQualityHintUrl, 'https://pan.quark.cn/s/22277d412f73');
    expect(detail.lrcContent, contains('[ti:夜曲]'));
    expect(detail.lrcContent, contains('[ar:周杰伦]'));
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
