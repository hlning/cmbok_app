import 'package:flutter/material.dart';

/// 应用常量配置
class AppConstants {
  static const String appName = 'Cmbok';
  static const String version = '2.0.3';

  /// 拷贝漫画 API 地址
  static const String defaultCopyApiUrl = 'https://api.copy3000.com/';

  /// z-library 域名（zh.zlibrary.by 已验证可用；运行时跟随 301/302 重定向并持久化新域名）
  static const String zLibraryApiUrl = 'https://zh.zlibrary.by/';

  /// 每页加载数量
  static const int pageSize = 20;

  /// 漫画章节图片加载超时
  static const int imageTimeout = 30;

  /// 数据库名称
  static const String dbName = 'cmbok.db';

  /// 存储目录名称
  static const String downloadDir = 'Cmbok';
  static const String comicDir = 'Comics';
  static const String bookDir = 'Books';

  /// GitHub 仓库地址（关于页 + 检查更新）
  static const String githubUrl = 'https://github.com/hlning/cmbok_app';

  /// 「甜甜的小站」博客地址（我的页 + 更新弹窗）
  static const String blogUrl = 'https://bluemood.xiaomy.net/';

  /// GitHub Releases 最新版本接口（检查更新）
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/hlning/cmbok_app/releases/latest';

  /// 远程公告地址（同步 Windows 端，首页弹窗展示）
  static const String notificationUrl =
      'https://cdn.jsdelivr.net/gh/hlning/cmbok_app@main/notification.json';

  /// 远程最新地址配置（拷贝漫画 API / z-library 域名，启动时自动检测更新）
  static const String urlConfigUrl =
      'https://cdn.jsdelivr.net/gh/hlning/cmbok@main/url_config.json';

  /// QQ 群号
  static const String qqGroupNumber = '1003773005';

  /// 分享网盘下载地址（找不到安装包时回退）
  static const String shareUrl =
      'https://1812475725.share.123pan.cn/123pan/GSy8Vv-DupEv';
}

/// 主题配置
class AppTheme {
  static const double radius = 12.0;
  static const double cardElevation = 2.0;
  static const EdgeInsets padding = EdgeInsets.all(16.0);
  static const EdgeInsets cardPadding = EdgeInsets.all(12.0);
}
