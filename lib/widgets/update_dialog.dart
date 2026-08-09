import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';
import '../utils/constants.dart';

/// 更新内容预览的最大行数；超过则截断并显示「查看详情」。
const _kPreviewMaxLines = 5;

/// 展示"发现新版本"对话框；点"GitHub"打开 release 页，点"小破站"打开博客。
/// 更新内容较长时截断预览，点"查看详情"查看完整内容。
/// 供「我的」页手动检查更新 与 启动自动检查更新 复用。
void showUpdateAvailableDialog(BuildContext context, UpdateResult result) {
  final body = result.releaseBody;
  final hasBody = body != null && body.isNotEmpty;
  // 超过预览行数或较长单行即视为"显示不完"，出现「查看详情」。
  final isLongBody =
      hasBody &&
      (body.split('\n').length > _kPreviewMaxLines || body.length > 150);

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('最新版本 v${result.latestVersion}，当前 v${AppConstants.version}。'),
          if (hasBody) ...[
            const SizedBox(height: 12),
            Text(
              body,
              maxLines: _kPreviewMaxLines,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            if (isLongBody)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _showFullUpdateContent(
                    ctx,
                    body,
                    result.latestVersion ?? '',
                  ),
                  child: const Text('查看详情'),
                ),
              ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('是否前往下载？'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            launchUrl(
              Uri.parse(AppConstants.blogUrl),
              mode: LaunchMode.externalApplication,
            );
          },
          child: const Text('小破站'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            launchUrl(
              Uri.parse(result.releaseUrl ?? AppConstants.githubUrl),
              mode: LaunchMode.externalApplication,
            );
          },
          child: const Text('GitHub'),
        ),
      ],
    ),
  );
}

/// 展示完整更新内容（可滚动、可选中复制）。
void _showFullUpdateContent(BuildContext context, String body, String version) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(version.isEmpty ? '更新内容' : '更新内容 v$version'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(child: SelectableText(body)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
