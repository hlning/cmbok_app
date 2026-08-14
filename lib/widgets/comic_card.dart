import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/comic.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[ComicCard] $message');
  }
}

/// 漫画卡片组件
class ComicCard extends StatelessWidget {
  final Comic comic;
  final VoidCallback onTap;

  const ComicCard({super.key, required this.comic, required this.onTap});

  @override
  Widget build(BuildContext context) {
    _log('构建卡片: ${comic.title}');

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, // 关键：最小化高度
          children: [
            // 封面（固定比例，不用Expanded）
            AspectRatio(
              aspectRatio: 3 / 4, // 漫画封面常用比例 3:4
              child: SizedBox(
                width: double.infinity,
                child: CachedNetworkImage(
                  imageUrl: comic.cover,
                  fit: BoxFit.cover,
                  memCacheWidth: 300,
                  placeholder: (context, url) => Container(
                    color: Colors.grey[200],
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: Colors.grey[200],
                    child: const Icon(Icons.broken_image, size: 40),
                  ),
                ),
              ),
            ),
            // 信息（固定高度，不用Expanded）
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min, // 关键：最小化高度
                children: [
                  Text(
                    comic.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (comic.author != null && comic.author!.isNotEmpty)
                    Text(
                      comic.author!,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
