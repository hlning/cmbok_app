import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookshelf.dart';
import '../models/comic.dart';
import 'bookshelf_service.dart';
import 'comic_api.dart';
import 'settings_service.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[Download] $message');
  }
}

/// 章节排序键：优先取标题中的首个数字（如"第30话"->30），回退 [order]。
/// copymanga 的 ordered 字段不可靠（疑似全 0 或倒序），改用标题章节号排序，
/// 使"第1话"在前、"第30话"在后。
int chapterSortKey(String title, int order) {
  final m = RegExp(r'\d+').firstMatch(title);
  return m != null ? (int.tryParse(m.group(0)!) ?? order) : order;
}

/// 章节展示排序键：按「话/卷/番外」类型分组，同类内按章节号升序。
/// 详情页 / 下载章节弹窗 / 下载管理页 / 离线阅读器统一使用本函数，
/// 保证各处章节顺序一致，避免阅读与下载顺序对不上。
int chapterDisplaySortKey(String title, int order) {
  final lower = title.toLowerCase();
  int typeRank;
  if (title.contains('话') || title.contains('話')) {
    typeRank = 0;
  } else if (title.contains('卷') ||
      title.contains('巻') ||
      lower.contains('vol')) {
    typeRank = 1;
  } else if (title.contains('番外') ||
      title.contains('外传') ||
      title.contains('特别') ||
      lower.contains('extra') ||
      lower.contains('special')) {
    typeRank = 2;
  } else {
    typeRank = 3;
  }
  final m = RegExp(r'\d+').firstMatch(title);
  final number = m != null ? (int.tryParse(m.group(0)!) ?? order) : order;
  // 类型在高位、章节号在低位；章节号预期远小于 100000
  return typeRank * 100000 + (number < 0 ? 0 : number);
}

/// 下载状态
enum DownloadStatus { queued, downloading, completed, failed, paused }

/// 单章下载任务（含漫画/章节元信息，供下载管理页显示与持久化）
class DownloadTask {
  /// 唯一键：'$comicPathWord/$chapterId'
  final String key;
  final String comicPathWord;
  final String comicTitle;
  final String comicCover;
  final String chapterId;
  final String chapterTitle;
  final int chapterOrder;
  DownloadStatus status;
  double progress; // 0~1
  int totalImages;
  int downloadedImages;
  int missingImages; // 缺失图片数（超时/失败跳过）
  String? error;
  int? downloadedAt; // 完成时间戳（ms）
  String? epubPath; // 合并生成的 EPUB 文件路径（持久化）

  /// 运行时取消令牌（不持久化）
  CancelToken? cancelToken;

  /// 续传标记（运行时，不持久化）：true 时跳过已下载图片接着下，不重置进度
  bool resumeMode = false;

  DownloadTask({
    required this.key,
    required this.comicPathWord,
    required this.comicTitle,
    required this.comicCover,
    required this.chapterId,
    required this.chapterTitle,
    this.chapterOrder = 0,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.totalImages = 0,
    this.downloadedImages = 0,
    this.missingImages = 0,
    this.error,
    this.downloadedAt,
    this.epubPath,
  });

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final pathWord = j['comicPathWord'] as String? ?? '';
    final chapterId = j['chapterId'] as String? ?? '';
    return DownloadTask(
      key: '$pathWord/$chapterId',
      comicPathWord: pathWord,
      comicTitle: j['comicTitle'] as String? ?? '',
      comicCover: j['comicCover'] as String? ?? '',
      chapterId: chapterId,
      chapterTitle: j['chapterTitle'] as String? ?? '',
      chapterOrder: j['chapterOrder'] as int? ?? 0,
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => DownloadStatus.completed,
      ),
      totalImages: j['totalImages'] as int? ?? 0,
      missingImages: j['missingImages'] as int? ?? 0,
      downloadedAt: j['downloadedAt'] as int?,
      epubPath: j['epubPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'comicPathWord': comicPathWord,
    'comicTitle': comicTitle,
    'comicCover': comicCover,
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'chapterOrder': chapterOrder,
    'status': status.name,
    'totalImages': totalImages,
    'missingImages': missingImages,
    'downloadedAt': downloadedAt,
    'epubPath': epubPath,
  };
}

/// 下载服务（队列 + 两级并发 + 本地持久化）
/// 单例 + ChangeNotifier，UI 用 ListenableBuilder 监听变化。
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;

  static const _recordsKey = 'downloaded_records';

  final ComicApi _api = ComicApi();
  final Dio _imageDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  /// 全部任务（queued/downloading/completed/failed），key = '$pathWord/$chapterId'
  final Map<String, DownloadTask> _tasks = {};
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  /// 已下载章节快速查询：pathWord -> {chapterId...}（从记录重建）
  final Map<String, Set<String>> _downloaded = {};

  /// 图片下载请求头（参考 ImageLoader，copymanga 图床校验 Referer）
  static const _imageHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://2025copy.com/',
  };

  /// 进行中（排队/下载中/失败）任务
  List<DownloadTask> get activeTasks =>
      _tasks.values.where((t) => t.status != DownloadStatus.completed).toList();

  /// 已完成任务
  List<DownloadTask> get completedTasks =>
      _tasks.values.where((t) => t.status == DownloadStatus.completed).toList();

  int get _runningCount =>
      _tasks.values.where((t) => t.status == DownloadStatus.downloading).length;

  /// 进度通知节流：大批量下载时每张图完成都 notify 会淹没主线程消息队列
  /// （"Failed to post message to main thread" 卡死）。仅图片进度更新走节流，
  /// 状态变更（开始/完成/失败/暂停/取消）仍即时 notify。
  DateTime? _lastProgressNotify;
  Timer? _progressNotifyTimer;

  /// 落盘节流：大批量下载时章节频繁完成，避免每章都编码全任务写 prefs。
  DateTime? _lastPersist;
  Timer? _persistTrailingTimer;

  /// 初始化：从本地恢复已下载记录
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_recordsKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          final task = DownloadTask.fromJson(item as Map<String, dynamic>);
          _tasks[task.key] = task;
          // 仅 completed/paused 视为已下载（有本地文件）；failed 不计入，
          // 否则 isChapterDownloaded 误判、downloadChapters 会跳过重下。
          if (task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.paused) {
            _downloaded.putIfAbsent(task.comicPathWord, () => <String>{});
            _downloaded[task.comicPathWord]!.add(task.chapterId);
          }
        }
      }
      _log('已加载 ${_tasks.length} 条下载记录');
    } catch (e) {
      _log('加载下载记录失败: $e');
    }
    // 应用退出时正在下载(downloading)的任务已被中断，转回排队重新调度；
    // 整章从头重下（resumeMode=false），避免被杀时残留的半截图片被误判为完整。
    var hasQueued = false;
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.downloading) {
        t.status = DownloadStatus.queued;
        hasQueued = true;
      } else if (t.status == DownloadStatus.queued) {
        hasQueued = true;
      }
    }
    notifyListeners();
    if (hasQueued) _schedule();
    // 补加历史已下载到"已下载的书"书架（幂等）
    await _syncDownloadedToShelf();
  }

  /// 启动时把历史已下载漫画补加到"已下载的书"书架（幂等，每本仅一条）
  Future<void> _syncDownloadedToShelf() async {
    final seen = <String>{};
    final items = <BookshelfItem>[];
    for (final t in _tasks.values) {
      if (t.status != DownloadStatus.completed) continue;
      if (!seen.add(t.comicPathWord)) continue;
      final snapshot = Comic(
        id: t.comicPathWord,
        title: t.comicTitle,
        cover: t.comicCover,
        pathWord: t.comicPathWord,
      );
      items.add(
        BookshelfItem(
          bookshelfId: BookshelfService.presetDownloaded,
          itemId: t.comicPathWord,
          type: BookshelfItemType.comic,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          meta: jsonEncode(snapshot.toJson()),
        ),
      );
    }
    if (items.isNotEmpty) {
      await BookshelfService().ensureItemsInShelf(items);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final records = _tasks.values
          .where(
            (t) =>
                t.status == DownloadStatus.completed ||
                t.status == DownloadStatus.paused ||
                t.status == DownloadStatus.failed ||
                t.status == DownloadStatus.queued ||
                t.status == DownloadStatus.downloading,
          )
          .map((t) => t.toJson())
          .toList();
      await prefs.setString(_recordsKey, jsonEncode(records));
    } catch (e) {
      _log('保存下载记录失败: $e');
    }
  }

  /// 节流版进度通知：最多每 150ms 触发一次，并在窗口内排一个尾随通知，
  /// 保证最终进度必刷新。仅用于图片下载进度更新，避免大批量下载时
  /// 每张图完成都 notify 淹没主线程消息队列导致卡死。
  void _notifyProgress() {
    final now = DateTime.now();
    if (_lastProgressNotify == null ||
        now.difference(_lastProgressNotify!) >=
            const Duration(milliseconds: 150)) {
      _lastProgressNotify = now;
      notifyListeners();
      return;
    }
    // 节流窗口内已有尾随通知则不重复排
    _progressNotifyTimer ??= Timer(const Duration(milliseconds: 150), () {
      _progressNotifyTimer = null;
      _lastProgressNotify = DateTime.now();
      notifyListeners();
    });
  }

  /// 节流版落盘：最多每 1s 一次，窗口内排尾随保证最终必落盘。
  /// 仅用于下载流程中的章节完成/失败；用户主动操作（暂停/取消/删除等）
  /// 仍直接调 _persist() 即时写入。
  void _schedulePersist() {
    final now = DateTime.now();
    if (_lastPersist == null ||
        now.difference(_lastPersist!) >= const Duration(seconds: 1)) {
      _lastPersist = now;
      _persist();
      return;
    }
    // 节流窗口内已有尾随落盘则不重复排
    _persistTrailingTimer ??= Timer(const Duration(seconds: 1), () {
      _persistTrailingTimer = null;
      _lastPersist = DateTime.now();
      _persist();
    });
  }

  /// 章节是否已下载
  bool isChapterDownloaded(String pathWord, String chapterId) {
    return _downloaded[pathWord]?.contains(chapterId) ?? false;
  }

  /// 漫画下载目录名：标题_pathWord。
  /// 标题在前可读，pathWord 在后保证唯一（防同名漫画目录冲突/误删）；
  /// 对标题做通用文件名净化（非法字符、超长、尾部点与空白），空标题回退 pathWord。
  String _comicDirName(String pathWord, String title) {
    var name = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    name = name.replaceAll(RegExp(r'[.\s]+$'), '');
    const maxLen = 80;
    if (name.length > maxLen) {
      name = name.substring(0, maxLen).replaceAll(RegExp(r'[.\s]+$'), '');
    }
    if (name.isEmpty) return pathWord;
    return '${name}_$pathWord';
  }

  /// 章节目录（下载/读取用，自动创建）
  Future<Directory> _chapterDir(
    String pathWord,
    String title,
    String chapterId,
  ) async {
    final base = await SettingsService.downloadBaseDir();
    final dir = Directory(
      '${base.path}/Comics/${_comicDirName(pathWord, title)}/$chapterId',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 读取本地图片路径列表（阅读页离线读）；未下载或无文件返回空。
  /// 先查标题命名的新目录，未命中回退旧 pathWord 目录，兼容历史下载。
  Future<List<String>> getLocalImages(
    String pathWord,
    String title,
    String chapterId,
  ) async {
    if (!isChapterDownloaded(pathWord, chapterId)) return [];
    try {
      final base = await SettingsService.downloadBaseDir();
      for (final folder in {_comicDirName(pathWord, title), pathWord}) {
        final dir = Directory('${base.path}/Comics/$folder/$chapterId');
        if (!await dir.exists()) continue;
        final files = dir.listSync().whereType<File>().toList();
        if (files.isEmpty) continue;
        files.sort((a, b) => a.path.compareTo(b.path));
        return files.map((f) => f.path).toList();
      }
      return [];
    } catch (e) {
      _log('读取本地图片失败: $e');
      return [];
    }
  }

  /// 加入下载队列（立即返回，不阻塞）。已下载/已在队列的跳过。
  void downloadChapters(Comic comic, List<ComicChapter> chapters) {
    var added = 0;
    for (final chapter in chapters) {
      if (isChapterDownloaded(comic.pathWord, chapter.id)) continue;
      final key = '${comic.pathWord}/${chapter.id}';
      final existing = _tasks[key];
      if (existing != null &&
          existing.status != DownloadStatus.completed &&
          existing.status != DownloadStatus.failed) {
        continue; // 已在队列或下载中
      }
      _tasks[key] = DownloadTask(
        key: key,
        comicPathWord: comic.pathWord,
        comicTitle: comic.title,
        comicCover: comic.cover,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        chapterOrder: chapter.order,
        status: DownloadStatus.queued,
      );
      added++;
    }
    if (added > 0) {
      notifyListeners();
      _persist(); // 立即持久化排队任务，退出软件不丢
      _schedule();
    }
  }

  /// 调度：按"同时下载量"并发启动排队任务
  void _schedule() {
    final maxChapters = SettingsService().maxConcurrentChapters;
    while (_runningCount < maxChapters) {
      final next = _nextQueued();
      if (next == null) break;
      _startTask(next);
    }
  }

  DownloadTask? _nextQueued() {
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.queued) return t;
    }
    return null;
  }

  void _startTask(DownloadTask task) {
    task.status = DownloadStatus.downloading;
    if (!task.resumeMode) {
      task.progress = 0;
      task.downloadedImages = 0;
    }
    task.cancelToken = CancelToken();
    notifyListeners();
    _downloadOne(task).whenComplete(_schedule);
  }

  Future<void> _downloadOne(DownloadTask task) async {
    try {
      final urls = await _api.getChapterImages(
        task.comicPathWord,
        task.chapterId,
      );
      if (!_tasks.containsKey(task.key)) return; // 已取消（移除）
      if (task.status == DownloadStatus.paused) return; // 已暂停
      if (urls.isEmpty) {
        task.status = DownloadStatus.failed;
        task.error = '无图片';
        _schedulePersist();
        notifyListeners();
        _log('章节无图片: ${task.chapterTitle}');
        return;
      }
      task.totalImages = urls.length;
      final dir = await _chapterDir(
        task.comicPathWord,
        task.comicTitle,
        task.chapterId,
      );

      // 续传：扫描已下载的完整图片并跳过（暂停时 Dio 已删除未写完的分片，
      // 磁盘只剩完整的 NNN.jpg），仅补下缺失项
      final existing = <int>{};
      if (task.resumeMode) {
        try {
          for (final f in dir.listSync().whereType<File>()) {
            final name = f.path.split(RegExp(r'[/\\]')).last;
            final m = RegExp(r'^(\d+)\.jpg$').firstMatch(name);
            if (m != null) {
              final idx = int.parse(m.group(1)!) - 1;
              if (idx >= 0 && idx < urls.length) existing.add(idx);
            }
          }
        } catch (e) {
          _log('扫描已下载图片失败: $e');
        }
        if (existing.isNotEmpty) {
          task.downloadedImages = existing.length;
          task.progress = existing.length / urls.length;
          notifyListeners();
          _log(
            '续传 ${task.chapterTitle}：跳过 ${existing.length}/${urls.length} 张',
          );
        }
      }

      final maxImages = SettingsService().maxConcurrentImages;
      await _downloadImagesConcurrent(
        urls,
        task,
        dir,
        maxImages,
        existing,
        existing.length,
      );
      if (!_tasks.containsKey(task.key)) return; // 已取消（移除）
      if (task.status == DownloadStatus.paused) return; // 已暂停
      if (task.downloadedImages == 0) {
        // 一张都没下载成功 -> 失败（避免空章节算完成）
        task.status = DownloadStatus.failed;
        task.error = '图片下载失败';
        _schedulePersist();
        notifyListeners();
        _log('章节下载失败（无图片）: ${task.chapterTitle}');
        return;
      }
      task.status = DownloadStatus.completed;
      task.progress = 1;
      task.downloadedAt = DateTime.now().millisecondsSinceEpoch;
      _downloaded.putIfAbsent(task.comicPathWord, () => <String>{});
      _downloaded[task.comicPathWord]!.add(task.chapterId);
      // 自动加入"已下载的书"书架（幂等，首次下载完成即加入）
      final snapshot = Comic(
        id: task.comicPathWord,
        title: task.comicTitle,
        cover: task.comicCover,
        pathWord: task.comicPathWord,
      );
      await BookshelfService().addToBookshelf(
        BookshelfService.presetDownloaded,
        task.comicPathWord,
        BookshelfItemType.comic,
        meta: jsonEncode(snapshot.toJson()),
      );
      // 合并 EPUB（若开启）
      if (SettingsService().mergeChapterToEpub) {
        final epub = await _mergeChapterToEpub(task, dir);
        if (epub != null) {
          task.epubPath = epub;
          if (!SettingsService().keepImagesAfterEpub) {
            await _deleteChapterImages(dir);
          }
        }
      }
      _schedulePersist();
      notifyListeners();
      _log(
        '章节下载完成: ${task.chapterTitle} '
        '(${task.downloadedImages}/${task.totalImages} 张'
        '${task.missingImages > 0 ? '，缺 ${task.missingImages} 张' : ''})',
      );
    } catch (e) {
      if (!_tasks.containsKey(task.key)) return; // 已取消（移除），静默
      if (task.status == DownloadStatus.paused) return; // 已暂停，静默
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _schedulePersist();
      notifyListeners();
      _log('章节下载失败: ${task.chapterTitle} - $e');
    }
  }

  /// 并发下载单章图片（按"分片并发量"控制并发数）
  /// [existing] 为已下载的完整图片索引（续传时跳过），[alreadyDone] 为其数量（用于进度）。
  /// 单张超时/失败不终止整章：跳过并记入 [DownloadTask.missingImages]，
  /// 由 [_downloadOne] 依据 downloadedImages 决定最终 completed/failed。
  Future<void> _downloadImagesConcurrent(
    List<String> urls,
    DownloadTask task,
    Directory dir,
    int concurrency,
    Set<int> existing,
    int alreadyDone,
  ) async {
    final total = urls.length;
    // 仅下载缺失的图片
    final pending = <int>[];
    for (var i = 0; i < total; i++) {
      if (!existing.contains(i)) pending.add(i);
    }
    if (pending.isEmpty) {
      task.missingImages = 0;
      return;
    }

    final completer = Completer<void>();
    var next = 0;
    var done = 0;
    var failedCount = 0;

    void startOne() {
      if (completer.isCompleted) return;
      if (next >= pending.length) {
        if (done + failedCount == pending.length && !completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      final i = pending[next++];
      final fileName = '${(i + 1).toString().padLeft(3, '0')}.jpg';
      final file = File('${dir.path}/$fileName');
      _imageDio
          .download(
            urls[i],
            file.path,
            options: Options(headers: _imageHeaders),
            cancelToken: task.cancelToken,
          )
          .then((_) {
            done++;
            task.downloadedImages = alreadyDone + done;
            task.progress = (alreadyDone + done + failedCount) / total;
            _notifyProgress();
            startOne();
          })
          .catchError((e) {
            // 用户取消：终止整章（交由 _downloadOne 的 catch 静默处理）
            final isCancel =
                e is DioException && e.type == DioExceptionType.cancel;
            if (isCancel) {
              if (!completer.isCompleted) completer.completeError(e);
              return;
            }
            // 超时/网络错误：跳过单张，继续下载其余
            failedCount++;
            task.missingImages = failedCount;
            try {
              if (file.existsSync()) file.deleteSync();
            } catch (_) {}
            task.progress = (alreadyDone + done + failedCount) / total;
            _notifyProgress();
            startOne();
          });
    }

    final initial = concurrency < pending.length ? concurrency : pending.length;
    for (var i = 0; i < initial; i++) {
      startOne();
    }
    await completer.future;
  }

  /// 重试失败任务
  void retryTask(String key) {
    final task = _tasks[key];
    if (task == null || task.status != DownloadStatus.failed) return;
    task.status = DownloadStatus.queued;
    task.error = null;
    task.progress = 0;
    task.downloadedImages = 0;
    task.missingImages = 0;
    task.resumeMode = false;
    notifyListeners();
    _schedule();
  }

  /// 重新下载已完成章节中缺失的图片（超时跳过的）
  void redownloadMissing(String key) {
    final task = _tasks[key];
    if (task == null ||
        task.status != DownloadStatus.completed ||
        task.missingImages <= 0) {
      return;
    }
    task.status = DownloadStatus.queued;
    task.error = null;
    task.resumeMode = true; // 续传：扫描已有文件，只下缺失的
    if (task.totalImages > 0) {
      task.progress = task.downloadedImages / task.totalImages;
    }
    notifyListeners();
    _schedule();
  }

  /// 取消排队/下载中/暂停任务（停止下载并移除）
  void cancelTask(String key) {
    final task = _tasks[key];
    if (task == null) return;
    final needPersist =
        task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.completed;
    task.cancelToken?.cancel();
    _tasks.remove(key);
    if (needPersist) _persist();
    notifyListeners();
  }

  /// 删除已下载任务（删文件 + 记录）
  Future<void> deleteTask(String key) async {
    final task = _tasks[key];
    if (task == null) return;
    await _deleteFiles(task.comicPathWord, task.comicTitle, task.chapterId);
    await _deleteEpub(task);
    _downloaded[task.comicPathWord]?.remove(task.chapterId);
    if (_downloaded[task.comicPathWord]?.isEmpty ?? false) {
      _downloaded.remove(task.comicPathWord);
    }
    _tasks.remove(key);
    await _persist();
    notifyListeners();
  }

  /// 清空所有已完成任务
  Future<void> clearCompleted() async {
    final keys = _tasks.entries
        .where((e) => e.value.status == DownloadStatus.completed)
        .map((e) => e.key)
        .toList();
    for (final key in keys) {
      final task = _tasks[key]!;
      await _deleteFiles(task.comicPathWord, task.comicTitle, task.chapterId);
      await _deleteEpub(task);
      _downloaded[task.comicPathWord]?.remove(task.chapterId);
      _tasks.remove(key);
    }
    _downloaded.removeWhere((_, s) => s.isEmpty);
    await _persist();
    notifyListeners();
  }

  /// 暂停单个任务（排队/下载中 -> 已暂停，停止在传下载）
  void pauseTask(String key) {
    final task = _tasks[key];
    if (task == null) return;
    if (task.status != DownloadStatus.queued &&
        task.status != DownloadStatus.downloading) {
      return;
    }
    task.cancelToken?.cancel();
    task.status = DownloadStatus.paused;
    _persist();
    notifyListeners();
  }

  /// 继续单个任务（已暂停 -> 排队，续传：保留进度，跳过已下载图片）
  void resumeTask(String key) {
    final task = _tasks[key];
    if (task == null || task.status != DownloadStatus.paused) return;
    task.status = DownloadStatus.queued;
    task.resumeMode = true; // 续传：不重置进度
    notifyListeners();
    _schedule();
  }

  /// 全部暂停：排队/下载中 -> 已暂停
  void pauseAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading) {
        t.cancelToken?.cancel();
        t.status = DownloadStatus.paused;
        changed = true;
      }
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// 全部继续：已暂停 -> 排队，续传（保留进度，跳过已下载图片）
  void resumeAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.paused) {
        t.status = DownloadStatus.queued;
        t.resumeMode = true; // 续传：不重置进度
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  /// 全部开始：已暂停 -> 排队，从头重新下载（重置进度）
  void restartAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.paused) {
        t.status = DownloadStatus.queued;
        t.progress = 0;
        t.downloadedImages = 0;
        t.missingImages = 0;
        t.resumeMode = false;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  /// 全部重试：失败 -> 排队，重新调度
  void retryAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.failed) {
        t.status = DownloadStatus.queued;
        t.error = null;
        t.progress = 0;
        t.downloadedImages = 0;
        t.missingImages = 0;
        t.resumeMode = false;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  /// 全部取消：移除所有非已完成任务（排队/下载中/暂停/失败）
  void cancelAll() {
    final keys = _tasks.entries
        .where((e) => e.value.status != DownloadStatus.completed)
        .map((e) => e.key)
        .toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      _tasks[key]?.cancelToken?.cancel();
      _tasks.remove(key);
    }
    _persist();
    notifyListeners();
  }

  /// 删除整本漫画的所有下载（文件 + 记录）
  Future<void> deleteComic(String pathWord) async {
    final keys = _tasks.entries
        .where((e) => e.value.comicPathWord == pathWord)
        .map((e) => e.key)
        .toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final task = _tasks[key]!;
      await _deleteFiles(task.comicPathWord, task.comicTitle, task.chapterId);
      await _deleteEpub(task);
      _tasks.remove(key);
    }
    _downloaded.remove(pathWord);
    await _persist();
    notifyListeners();
  }

  /// 批量删除多本漫画的所有下载（文件 + 记录，一次持久化 + 一次通知）
  Future<void> deleteComics(Iterable<String> pathWords) async {
    final set = pathWords.toSet();
    final keys = _tasks.entries
        .where((e) => set.contains(e.value.comicPathWord))
        .map((e) => e.key)
        .toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final task = _tasks[key]!;
      await _deleteFiles(task.comicPathWord, task.comicTitle, task.chapterId);
      await _deleteEpub(task);
      _tasks.remove(key);
    }
    for (final pw in set) {
      _downloaded.remove(pw);
    }
    await _persist();
    notifyListeners();
  }

  /// 已下载章节列表（按 chapterOrder 排序，供阅读器构建 groups 离线阅读）
  List<ComicChapter> downloadedChapters(String pathWord) {
    final list = _tasks.values
        .where(
          (t) =>
              t.comicPathWord == pathWord &&
              t.status == DownloadStatus.completed,
        )
        .map(
          (t) => ComicChapter(
            id: t.chapterId,
            title: t.chapterTitle,
            order: t.chapterOrder,
            count: t.totalImages,
            groupId: 'default',
            groupName: '默认',
          ),
        )
        .toList();
    list.sort(
      (a, b) => chapterDisplaySortKey(
        a.title,
        a.order,
      ).compareTo(chapterDisplaySortKey(b.title, b.order)),
    );
    return list;
  }

  Future<void> _deleteFiles(
    String pathWord,
    String title,
    String chapterId,
  ) async {
    try {
      final base = await SettingsService.downloadBaseDir();
      // 删新目录与旧 pathWord 目录（兼容历史下载残留）
      for (final folder in {_comicDirName(pathWord, title), pathWord}) {
        final dir = Directory('${base.path}/Comics/$folder/$chapterId');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    } catch (e) {
      _log('删除文件失败: $e');
    }
  }

  /// 删除 EPUB 文件（若存在）
  Future<void> _deleteEpub(DownloadTask task) async {
    final p = task.epubPath;
    if (p == null || p.isEmpty) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (e) {
      _log('删除 EPUB 失败: $e');
    }
  }

  /// 删除章节目录下的图片（合并 EPUB 后不保留图片时调用）
  Future<void> _deleteChapterImages(Directory dir) async {
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.path.split(RegExp(r'[/\\]')).last;
        if (RegExp(r'^\d+\.jpg$').hasMatch(name)) {
          await f.delete();
        }
      }
    } catch (e) {
      _log('删除章节图片失败: $e');
    }
  }

  /// 将章节图片合并为 EPUB（每章一个）。成功返回 EPUB 路径，失败返回 null。
  /// EPUB 输出到独立的 epub/ 子目录，避免被 getLocalImages 误当图片读取。
  Future<String?> _mergeChapterToEpub(
    DownloadTask task,
    Directory imageDir,
  ) async {
    try {
      // 收集并按序号排序的图片
      final images = <int, File>{};
      for (final f in imageDir.listSync().whereType<File>()) {
        final name = f.path.split(RegExp(r'[/\\]')).last;
        final m = RegExp(r'^(\d+)\.jpg$').firstMatch(name);
        if (m != null) {
          images[int.parse(m.group(1)!)] = f;
        }
      }
      if (images.isEmpty) return null;
      final sortedKeys = images.keys.toList()..sort();
      final pages = sortedKeys.length;
      final imagePaths = [for (final k in sortedKeys) images[k]!.path];

      final base = await SettingsService.downloadBaseDir();
      final epubDir = Directory(
        '${base.path}/Comics/${_comicDirName(task.comicPathWord, task.comicTitle)}/epub',
      );
      if (!await epubDir.exists()) {
        await epubDir.create(recursive: true);
      }
      final safeComic = _sanitizeEpubName(
        task.comicTitle.isEmpty ? task.comicPathWord : task.comicTitle,
        maxLen: 40,
      );
      final safeChapter = _sanitizeEpubName(
        task.chapterTitle.isEmpty ? task.chapterId : task.chapterTitle,
        maxLen: 40,
      );
      // 追加 chapterId 前8位：既防重名章节互相覆盖，又控制文件名总长
      final shortChapterId = task.chapterId.length > 8
          ? task.chapterId.substring(0, 8)
          : task.chapterId;
      final epubPath =
          '${epubDir.path}/${safeComic}_${safeChapter}_$shortChapterId.epub';

      final bookId = 'cmbok-${task.comicPathWord}-${task.chapterId}';
      final title = task.chapterTitle.isEmpty
          ? task.comicTitle
          : task.chapterTitle;

      // 预生成 XML（轻量字符串拼接，主线程）；zip 压缩等重活交 worker isolate，
      // 避免 ZipEncoder().encode 阻塞主线程导致大批量下载卡死。
      final pageXhtmls = <String>[];
      for (var i = 1; i <= pages; i++) {
        pageXhtmls.add(_epubPageXhtml(i));
      }
      final epub = await compute(
        _buildEpubInIsolate,
        _EpubBuildRequest(
          imagePaths: imagePaths,
          epubPath: epubPath,
          containerXml: _epubContainerXml(),
          contentOpfXml: _epubContentOpf(title, task.comicTitle, bookId, pages),
          tocNcxXml: _epubTocNcx(title, bookId, pages),
          pageXhtmls: pageXhtmls,
        ),
      );
      if (epub == null) return null;
      _log('已合并 EPUB: ${task.chapterTitle} ($pages 页) -> $epubPath');
      return epub;
    } catch (e) {
      _log('合并 EPUB 失败: ${task.chapterTitle} - $e');
      return null;
    }
  }

  String _sanitizeEpubName(String s, {int maxLen = 80}) {
    var name = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    if (name.isEmpty) name = 'chapter';
    if (name.length > maxLen) name = name.substring(0, maxLen);
    return name;
  }

  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String _epubContainerXml() =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
      '  <rootfiles>\n'
      '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
      '  </rootfiles>\n'
      '</container>';

  String _epubContentOpf(
    String title,
    String author,
    String bookId,
    int pages,
  ) {
    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln(
      '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">',
    );
    b.writeln(
      '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">',
    );
    b.writeln('    <dc:title>${_xmlEscape(title)}</dc:title>');
    b.writeln('    <dc:creator>${_xmlEscape(author)}</dc:creator>');
    b.writeln('    <dc:language>zh</dc:language>');
    b.writeln(
      '    <dc:identifier id="BookId">urn:uuid:${_xmlEscape(bookId)}</dc:identifier>',
    );
    b.writeln('  </metadata>');
    b.writeln('  <manifest>');
    b.writeln(
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    );
    for (var i = 1; i <= pages; i++) {
      b.writeln(
        '    <item id="img-$i" href="images/img-$i.jpg" media-type="image/jpeg"/>',
      );
      b.writeln(
        '    <item id="page-$i" href="page-$i.xhtml" media-type="application/xhtml+xml"/>',
      );
    }
    b.writeln('  </manifest>');
    b.writeln('  <spine toc="ncx">');
    for (var i = 1; i <= pages; i++) {
      b.writeln('    <itemref idref="page-$i"/>');
    }
    b.writeln('  </spine>');
    b.writeln('</package>');
    return b.toString();
  }

  String _epubTocNcx(String title, String bookId, int pages) {
    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln(
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">',
    );
    b.writeln(
      '  <head><meta name="dtb:uid" content="urn:uuid:${_xmlEscape(bookId)}"/></head>',
    );
    b.writeln('  <docTitle><text>${_xmlEscape(title)}</text></docTitle>');
    b.writeln('  <navMap>');
    for (var i = 1; i <= pages; i++) {
      b.writeln('    <navPoint id="nav-$i" playOrder="$i">');
      b.writeln('      <navLabel><text>第 $i 页</text></navLabel>');
      b.writeln('      <content src="page-$i.xhtml"/>');
      b.writeln('    </navPoint>');
    }
    b.writeln('  </navMap>');
    b.writeln('</ncx>');
    return b.toString();
  }

  String _epubPageXhtml(int i) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第 $i 页</title></head>\n'
      '<body><div style="text-align:center;"><img src="images/img-$i.jpg" alt="第 $i 页"/></div></body></html>';
}

/// EPUB 构建请求（跨 isolate 传递）：主线程收集图片路径与预生成的 XML，
/// worker isolate 内读图、压缩、写文件，避免 zip 编码阻塞主线程。
class _EpubBuildRequest {
  final List<String> imagePaths;
  final String epubPath;
  final String containerXml;
  final String contentOpfXml;
  final String tocNcxXml;
  final List<String> pageXhtmls;

  _EpubBuildRequest({
    required this.imagePaths,
    required this.epubPath,
    required this.containerXml,
    required this.contentOpfXml,
    required this.tocNcxXml,
    required this.pageXhtmls,
  });
}

/// worker isolate 内构建 EPUB：读图 + archive + zip 编码 + 写文件。
/// ZipEncoder().encode 是 CPU 密集操作，移出主 isolate 避免卡死。
Future<String?> _buildEpubInIsolate(_EpubBuildRequest req) async {
  try {
    final archive = Archive();
    final mt = utf8.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress('mimetype', mt.length, mt));
    archive.addFile(
      ArchiveFile('META-INF/container.xml', 0, utf8.encode(req.containerXml)),
    );
    archive.addFile(
      ArchiveFile('OEBPS/content.opf', 0, utf8.encode(req.contentOpfXml)),
    );
    archive.addFile(
      ArchiveFile('OEBPS/toc.ncx', 0, utf8.encode(req.tocNcxXml)),
    );
    for (var i = 0; i < req.imagePaths.length; i++) {
      final n = i + 1;
      archive.addFile(
        ArchiveFile('OEBPS/page-$n.xhtml', 0, utf8.encode(req.pageXhtmls[i])),
      );
      final imgBytes = await File(req.imagePaths[i]).readAsBytes();
      archive.addFile(ArchiveFile('OEBPS/images/img-$n.jpg', 0, imgBytes));
    }
    final bytes = ZipEncoder().encode(archive);
    if (bytes == null) return null;
    await File(req.epubPath).writeAsBytes(bytes);
    return req.epubPath;
  } catch (e) {
    _log('worker isolate 合并 EPUB 失败: $e');
    return null;
  }
}
