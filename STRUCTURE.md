# 代码结构速查

## pages/ — 页面

| 文件 | 功能 |
|---|---|
| `reader_page.dart` | 漫画阅读器（翻页/拼页/消散 + 双页 + 横竖屏） |
| `book_reader_page.dart` | 图书阅读器（分页/仿真 + 双页） |
| `bookshelf_page.dart` | 书架首页 |
| `search_page.dart` | 漫画搜索 |
| `book_search_page.dart` | 图书搜索（zlibrary） |
| `comic_detail_page.dart` | 漫画详情/章节 |
| `book_detail_page.dart` | 图书详情 |
| `download_page.dart` | 下载管理 |
| `favorites_page.dart` | 收藏 |
| `me_page.dart` | 我的/设置入口 |
| `reading_settings_page.dart` | 阅读设置 |
| `home_page.dart` | 分类/发现 |
| `book_prefetch_page.dart` | 图书预读分页页 |
| `display_settings_page.dart` | 显示设置 |
| `download_settings_page.dart` | 下载设置 |
| `peer_transfer_page.dart` | 跨设备传书 |
| `source_repo_page.dart` | 漫画源仓库 |
| `zlibrary_auth_page.dart` | Z-Library 登录 |
| `about_page.dart` | 关于页 |
| `pdf_reader_page.dart` | PDF 阅读器（备用，已弃用主路径） |

## services/ — 业务服务（ChangeNotifier 单例为主）

| 文件 | 功能 |
|---|---|
| `settings_service.dart` | 全局设置（阅读模式/主题/下载等） |
| `reader_override_service.dart` | per-item 阅读设置覆盖（独立开关） |
| `download_service.dart` | 漫画下载 |
| `book_download_service.dart` | 图书下载 |
| `favorites_service.dart` | 漫画收藏 |
| `book_favorites_service.dart` | 图书收藏 |
| `bookshelf_service.dart` | 书架 |
| `comic_api.dart` | CopyManga API（Dio + 重试 + UA） |
| `zlibrary_service.dart` | Z-Library API |
| `book_paginator.dart` | 图书分页（ui.Paragraph 测量） |
| `book_parser.dart` | 图书解析（epub/mobi/pdf） |
| `book_content_cache_service.dart` | 图书内容缓存 |
| `book_page_cache_service.dart` | 图书分页缓存 |
| `book_reading_progress_service.dart` | 图书阅读进度 |
| `reading_progress_service.dart` | 漫画阅读进度 |
| `peer_transfer_service.dart` | 跨设备传书（mDNS + HTTP） |
| `book_font_service.dart` | 图书字体管理 |
| `book_view_mode.dart` | 图书视图模式 |
| `view_mode.dart` | 漫画视图模式 |
| `theme_switch.dart` | 主题切换 |
| `platform_service.dart` | 平台能力封装 |
| `crypto.dart` | CopyManga 加解密 |
| `search_history_service.dart` | 搜索历史 |
| `remote_config_service.dart` | 远程配置 |
| `update_service.dart` | 版本更新检查 |
| `builtin_accounts.dart` | 内置账号 |

## z-library 云端探测（多节点容灾）

跨 `remote_config_service.dart` + `zlibrary_service.dart` 两服务，对应 Windows 端 `StartupCheckThread` + `ZlibraryHealthCheckThread`。目标：z-library 域名漂移频繁，靠云端下发候选 + 本地探测选优 + 运行时重定向发现，保证始终有可用节点。

### 配置来源（RemoteConfigService）
- `zlibraryDomain`（:49）：初始默认域名，仅 ZlibraryService 无持久化域名时作 fallback。
- `cloudZlibraryUrl`（:53）：云端 `zlibrary_url` 原始值（单字符串或数组），拉到后通知 ZlibraryService 归一化+探测。本地当前域名仍可用则不覆盖云端值（:26 注释）。

### ZlibraryService 状态字段
- `_domain`（:86）：当前使用域名（不含 scheme），持久化 `zlibrary_domain`。
- `_candidates`（:108）：候选节点列表，持久化 `zlibrary_url_candidates`（JSON 数组）。
- `_unavailable`（:111）：全候选不可用标志，仅状态变化才 notify，UI 据此提示「图书功能暂不可用」。
- `_lastAppliedCloud`（:117）：去重，避免 RemoteConfig 重复通知触发重复探测。
- `_healthTimer`（:114）：30 分钟定时健康检查（`_kHealthInterval`）。

### 三条探测路径
1. **启动探测**：`init()`（:138）注册 RemoteConfig 监听 -> `_onRemoteConfigChanged`（:167）/ `_applyCloudCandidatesIfAvailable`（:171）-> `applyCloudCandidates`（:1462）：`_normalizeCandidates` 归一化（:1481）-> `_pickBestCandidate` 并发选优（:1505）-> 写回 `_domain` + 完整候选列表 + 标记可用性。不阻塞 UI。
2. **定时健康检查**：`_healthCheck`（:1576）每 30min 先探当前域名，可用则保持；不可用才从候选重新选最优。
3. **运行时重定向发现**：`_send`（:1233）请求遇 301/302 跳新域名 -> `_maybeRedirect`（:1346）-> 更新 `_domain` + `_addCandidate`（:227）+ 在新域名重试一次（`followed` 标志防循环）。

### 探测实现
- `_pickBestCandidate`（:1505）：并发探测所有候选，延迟 <3s 的可用节点即提前返回，否则取最低延迟；全不可用返回 null。
- `_probeUrl`（:1537）：单节点探测，独立 Dio（6s 超时、跟随重定向、不抛异常），返回落地域名 + 延迟秒；能拿到 HTTP 响应即视为可用（根路径常返 503 但站点实际可用）。
- `_Probe`（:1602）：`(domain, latency)` 数据类。

### 候选感知请求 `_send`（:1233）
遍历 `_candidateOrder()`（:217，当前域名优先去重），逐域名尝试：
- **404** -> 域名非 z-library 主机，切下一候选。
- **连接异常**（DNS/超时/重置）-> 切下一候选。
- **重定向新域名** -> 更新 + 加候选 + 重试一次。
- **429/5xx** -> 同域名退避重试，`_retryWait`（:1334）优先 `Retry-After` 否则指数 2/4/8s，最多 3 次（`_kMaxRetries`）。
- **全候选失败/全 404** -> `_setUnavailable(true)`，返回 `{success:false, unavailable:true}`。

## source/ — 漫画源层

| 文件 | 功能 |
|---|---|
| `source_manager.dart` | 源管理（注册/切换/查找） |
| `manga_source.dart` | 源抽象接口（MangaSource） |
| `copy_manga_source.dart` | CopyManga 代码源 |
| `config_manga_source.dart` | 配置源（JSON 驱动 + DOM 选择器） |
| `source_definition.dart` | 源配置定义（SourceDefinition 数据类） |
| `source_config_store.dart` | 配置存储（远程+本地+内置三层兜底） |
| `site_config.dart` | 站点配置（site_configs.json 加载） |
| `adapter.dart` | 通用适配器（fetchHtml / fetchChapters / 3阶段 等） |
| `webview_image_fetcher.dart` | WebView 兜底取图（CF/防盗链） |
| `image_cache_manager.dart` | 图片缓存管理（flutter_cache_manager 封装） |
| `models.dart` | 源层数据模型 |
| `zaimanhua_source.dart` | 贼漫画源（旧代码源） |
| `zaimanhua_config.dart` | 贼漫画配置（旧） |
| `manhuaren_source.dart` | 漫画人源（旧代码源） |
| `manhuaren_config.dart` | 漫画人配置（旧） |

## models/ — 数据模型

`comic.dart` `book.dart` `bookshelf.dart` `book_category.dart` `book_content.dart` `search_result.dart` `peer_device.dart` `transfer_offer.dart`

## widgets/ — 通用组件（Jelly 风格）

卡片：`jelly_comic_card.dart` `jelly_book_card.dart` `comic_card.dart` `jelly_comic_list_tile.dart`
导航/栏：`jelly_nav_bar.dart` `jelly_search_bar.dart` `jelly_segmented_toggle.dart`
交互：`jelly_favorite_button.dart` `jelly_select_badge.dart` `jelly_score_badge.dart`
弹窗：`jelly_bookshelf_dialog.dart` `download_chapter_sheet.dart` `notification_popup.dart` `update_dialog.dart`
其他：`book_page_curl.dart`（仿真翻页） `bookshelf_icon.dart` `staggered_entrance.dart`

## theme/ — 主题

`jelly_theme.dart` — JellyTheme 常量（颜色/阴影/渐变/玻璃效果），支持 light/dark

## utils/ — 工具函数

`constants.dart` `cover_generator.dart` `image_loader.dart` `list_pagination.dart`

## 入口

`main.dart` — 初始化服务（FavoritesService 等）后 runApp
