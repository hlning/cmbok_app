import 'package:flutter/material.dart';

/// 列表懒加载分页工具。
///
/// 数据源是本地全量内存列表时，GridView/ListView.builder 本身懒构建可见项，
/// 这里在此基础上控制"一次渲染多少条"，避免每次 rebuild 全量遍历/解析，
/// 并配合滚动接近底部时追加下一批。
class ListPagination {
  ListPagination._();

  /// 每批渲染步长
  static const int pageSize = 30;

  /// 滚动接近底部（距 maxScrollExtent 不足 [threshold]）时返回 true，
  /// 用于触发"加载下一批"。
  static bool shouldLoadMore(
    ScrollController controller, {
    double threshold = 600,
  }) {
    if (!controller.hasClients) return false;
    final p = controller.position;
    if (!p.hasPixels || !p.hasContentDimensions) return false;
    return p.pixels > p.maxScrollExtent - threshold;
  }
}

/// 列表顶部"共 N 本/话"计数条（收藏/书架/下载页复用）。
class ListPaginationCountBar extends StatelessWidget {
  final int total;
  final String unit;

  const ListPaginationCountBar({
    super.key,
    required this.total,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '共 $total $unit',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
    );
  }
}
