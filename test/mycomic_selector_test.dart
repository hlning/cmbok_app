// mycomic 选择器 + 分类/搜索解析回归测试（全内联 HTML，不依赖外部文件）。
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

String _elText(Element el, String? selector) {
  if (selector == null || selector.isEmpty) return '';
  return el.querySelector(selector)?.text.trim() ?? '';
}

String? _elAttr(Element el, String? selector, String attr) {
  if (selector == null || selector.isEmpty) return null;
  return el.querySelector(selector)?.attributes[attr];
}

void main() {
  // 详情页信息卡（精简自站点 data-flux-card 结构）
  const detailCard = r'''<div class="p-6 rounded-xl bg-white" data-flux-card="">
    <div class="grow">
      <div data-flux-subheading="">2016 / 共 92 话</div>
      <div data-flux-heading="">炎拳</div>
      <div data-flux-badge="data-flux-badge">已完结</div>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-1 my-4">
        <div><label>原创作者:</label><span>
          <a href="https://mycomic.com/cn/comics?filter%5Bauthor%5D=%E8%97%A4%E6%9C%AC%E6%A8%B9">藤本樹</a>
        </span></div>
        <div><label>作品类型:</label><span>
          <a href="https://mycomic.com/cn/comics?filter%5Btag%5D=mohuan">魔幻</a>,
          <a href="https://mycomic.com/cn/comics?filter%5Btag%5D=maoxian">冒險</a>
        </span></div>
      </div>
      <div class="md:w-4/5 text-zinc-800">就因為一个被称為冰之魔女的祝福者，世界被冰雪笼罩。</div>
    </div>
    <div class="hidden sm:block"><img src="https://biccam.com/comics/20082-28afae.jpg" alt="炎拳"></div>
  </div>''';

  test('详情页选择器', () {
    final doc = parse(detailCard);
    expect(doc.querySelector('[data-flux-heading]')?.text.trim(), '炎拳');
    expect(
      doc.querySelector('[data-flux-card] img')?.attributes['src'],
      contains('biccam.com/comics/20082'),
    );
    // 作者作用域到 card，避免误匹配导航
    expect(
      doc.querySelector('[data-flux-card] a[href*="author"]')?.text.trim(),
      '藤本樹',
    );
    expect(doc.querySelector(r'.md\:w-4\/5')?.text.trim(), contains('冰之魔女'));
    expect(doc.querySelector('[data-flux-badge]')?.text.trim(), '已完结');
  });

  test('分类列表：30 卡解析 + 标题 alt 兜底 + 计数式 hasNext', () {
    final buf = StringBuffer('<html><body>');
    for (var i = 1; i <= 30; i++) {
      buf.write(
        '<div class="aspect-w-3 aspect-h-4 w-full overflow-hidden rounded-md bg-gray-200 relative">'
        '<a href="https://mycomic.com/cn/comics/$i">'
        '<img src="https://biccam.com/comics/$i-abc.jpg" alt="漫画$i">'
        '<div class="absolute top-0 left-0 w-full h-full">'
        '<div class="text-white text-sm pb-3 truncate">第01话</div></div>'
        '</a></div>',
      );
    }
    buf.write('</body></html>');
    final doc = parse(buf.toString());

    const listDom = '.aspect-w-3.aspect-h-4';
    const coverDom = 'img';
    const urlDom = 'a';
    const pageSize = 30;
    final items = <String>[];
    for (final r in doc.querySelectorAll(listDom)) {
      final href = _elAttr(r, urlDom, 'href') ?? '';
      if (href.isEmpty) continue;
      var title = _elText(r, '');
      if (title.isEmpty) title = _elAttr(r, coverDom, 'alt') ?? '';
      final cover = _elAttr(r, coverDom, 'src') ?? '';
      items.add('$title|$cover|$href');
    }
    expect(items.length, 30);
    expect(
      items.first,
      '漫画1|https://biccam.com/comics/1-abc.jpg|https://mycomic.com/cn/comics/1',
    );
    expect(items.length >= pageSize, true); // 满页 -> 有下一页

    // 末页 12 < 30 -> 无下一页
    final last = StringBuffer('<html><body>');
    for (var i = 1; i <= 12; i++) {
      last.write(
        '<div class="aspect-w-3 aspect-h-4"><a href="/cn/comics/$i">'
        '<img src="x$i.jpg" alt="末页$i"></a></div>',
      );
    }
    expect(
      parse(last.toString()).querySelectorAll(listDom).length >= pageSize,
      false,
    );
  });

  test('搜索：标题 alt 兜底', () {
    final doc = parse(
      '<div class="aspect-w-3 aspect-h-4">'
      '<a href="/cn/comics/9"><img src="c9.jpg" alt="搜索结果9"></a></div>',
    );
    for (final r in doc.querySelectorAll('.aspect-w-3.aspect-h-4')) {
      var title = _elText(r, '');
      final href = _elAttr(r, 'a', 'href') ?? '';
      if (title.isEmpty && href.isEmpty) continue;
      if (title.isEmpty) title = _elAttr(r, 'img', 'alt') ?? '';
      expect(title, '搜索结果9');
      expect(href, '/cn/comics/9');
    }
  });

  test('章节列表：chapterUrlPattern 过滤非章节链接', () {
    // 详情页 .mt-8.mb-12 区混有真章节链接与推荐等非章节链接（4 图推荐位）
    const chapterHtml = r'''<div class="mt-8 mb-12">
      <a href="https://mycomic.com/cn/chapters/20082-1">第01话</a>
      <a href="https://mycomic.com/cn/chapters/20082-2">第02话</a>
      <a href="https://mycomic.com/cn/comics/99999">人气推荐</a>
    </div>''';
    final doc = parse(chapterHtml);
    const linkDom = '.mt-8.mb-12 a';
    const urlPattern = '/cn/chapters/'; // mycomic 配置

    final chapters = <String>[];
    for (final a in doc.querySelectorAll(linkDom)) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty || href.startsWith('javascript:')) continue;
      // 与 ConfigMangaSource._parseChapters 相同的模式过滤
      if (urlPattern.isNotEmpty && !href.contains(urlPattern)) continue;
      chapters.add('${a.text.trim()}|$href');
    }
    expect(chapters.length, 2); // 推荐链接被排除
    expect(chapters.any((c) => c.contains('99999')), false);
    expect(chapters.first, contains('第01话'));
  });

  test('封面懒加载：src 为 data: 占位时取 data-src 真实 URL', () {
    // mycomic 列表 img 懒加载：初始 src=1x1 透明占位 data-uri，真实 URL 在 data-src
    const card = r'''<div class="aspect-w-3 aspect-h-4">
      <a href="https://mycomic.com/cn/comics/55268">
        <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mN09omrBwADNQFuUCqPAwAAAABJRU5ErkJggg=="
             data-src="https://biccam.com/comics/55268-338a02.jpg" alt="时间的神明">
      </a>
    </div>''';
    final doc = parse(card);
    final img = doc.querySelector('img');

    // 与 ConfigMangaSource._imgUrl 相同：跳过 data: 占位，取首个真实属性
    String? imgUrl(Element? el) {
      if (el == null) return null;
      for (final attr in const [
        'src',
        'data-src',
        'data-original',
        'data-lazy-src',
        'data-url',
      ]) {
        final v = el.attributes[attr];
        if (v != null && v.isNotEmpty && !v.startsWith('data:')) return v;
      }
      return el.attributes['src'];
    }

    expect(imgUrl(img), 'https://biccam.com/comics/55268-338a02.jpg');
    expect(imgUrl(img)?.startsWith('data:'), false);
  });
}
