import 'package:flutter/material.dart';
import '../models/bookshelf.dart';
import '../services/bookshelf_service.dart';
import '../theme/jelly_theme.dart';

/// 加入书架弹窗：多选书架 + 快速新建
/// 返回值：用户确认后返回选中的书架 ID 列表，取消返回 null
Future<List<String>?> showBookshelfDialog(
  BuildContext context, {
  required String itemId,
  required BookshelfItemType type,
  String? title,
  String? meta,
  bool singleSelect = false,
  Set<String>? disabledShelfIds,
}) async {
  return showModalBottomSheet<List<String>>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _BookshelfDialog(
      itemId: itemId,
      type: type,
      title: title,
      meta: meta,
      singleSelect: singleSelect,
      disabledShelfIds: disabledShelfIds,
    ),
  );
}

class _BookshelfDialog extends StatefulWidget {
  final String itemId;
  final BookshelfItemType type;
  final String? title;
  final String? meta;
  final bool singleSelect;
  final Set<String>? disabledShelfIds;

  const _BookshelfDialog({
    required this.itemId,
    required this.type,
    this.title,
    this.meta,
    this.singleSelect = false,
    this.disabledShelfIds,
  });

  @override
  State<_BookshelfDialog> createState() => _BookshelfDialogState();
}

class _BookshelfDialogState extends State<_BookshelfDialog> {
  late Set<String> _selected;
  final _newShelfController = TextEditingController();
  bool _showNewShelf = false;

  @override
  void initState() {
    super.initState();
    // 多选：预选当前所在书架；单选：不预选（移到其他书架是选新目标）
    _selected = widget.singleSelect
        ? <String>{}
        : BookshelfService()
              .getBookshelvesForItem(widget.itemId, widget.type)
              .toSet();
  }

  @override
  void dispose() {
    _newShelfController.dispose();
    super.dispose();
  }

  Future<void> _createNewShelf() async {
    final name = _newShelfController.text.trim();
    if (name.isEmpty) return;
    final shelf = await BookshelfService().createBookshelf(name);
    if (shelf != null) {
      setState(() {
        _selected.add(shelf.id);
        _showNewShelf = false;
        _newShelfController.clear();
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('书架名称已存在')));
      }
    }
  }

  void _confirm() {
    // 单选空选 = 取消移动，不动数据
    if (_selected.isEmpty && widget.singleSelect) {
      Navigator.pop(context);
      return;
    }
    // 保存到服务
    BookshelfService().setBookshelvesForItem(
      _selected.toList(),
      widget.itemId,
      widget.type,
      meta: widget.meta,
    );
    Navigator.pop(context, _selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E3A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部把手
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题
            Text(
              widget.title ?? '加入书架',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 12),
            // 新建书架输入框
            if (_showNewShelf)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newShelfController,
                        autofocus: true,
                        style: TextStyle(color: textColor, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '输入书架名称',
                          hintStyle: TextStyle(
                            color: isDark ? Colors.white38 : Colors.black38,
                            fontSize: 14,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark
                                  ? Colors.white12
                                  : Colors.black.withValues(alpha: 0.1),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark
                                  ? Colors.white12
                                  : Colors.black.withValues(alpha: 0.1),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: JellyTheme.primary,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _createNewShelf(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _createNewShelf,
                      child: const Text('创建'),
                    ),
                  ],
                ),
              ),
            // 书架列表
            ListenableBuilder(
              listenable: BookshelfService(),
              builder: (context, _) {
                final shelves = BookshelfService().bookshelves;
                if (shelves.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('暂无书架')),
                  );
                }
                return Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: shelves.length,
                    itemBuilder: (context, index) {
                      final shelf = shelves[index];
                      final selected = _selected.contains(shelf.id);
                      final disabled =
                          widget.disabledShelfIds?.contains(shelf.id) ?? false;
                      return _buildShelfTile(
                        shelf,
                        selected,
                        isDark,
                        textColor,
                        disabled,
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            // 新建书架按钮
            if (!_showNewShelf)
              InkWell(
                onTap: () => setState(() => _showNewShelf = true),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.add_rounded,
                        size: 20,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '新建书架',
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            // 确定按钮
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: JellyTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  '确定',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShelfTile(
    Bookshelf shelf,
    bool selected,
    bool isDark,
    Color textColor,
    bool disabled,
  ) {
    final dimColor = isDark ? Colors.white24 : Colors.black26;
    return InkWell(
      onTap: disabled
          ? null
          : () {
              setState(() {
                if (selected) {
                  _selected.remove(shelf.id);
                } else {
                  if (widget.singleSelect) _selected.clear();
                  _selected.add(shelf.id);
                }
              });
            },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? (widget.singleSelect
                        ? Icons.radio_button_checked_rounded
                        : Icons.check_circle_rounded)
                  : Icons.radio_button_unchecked_rounded,
              color: selected
                  ? JellyTheme.primary
                  : disabled
                  ? dimColor
                  : isDark
                  ? Colors.white38
                  : Colors.black38,
              size: 22,
            ),
            const SizedBox(width: 12),
            Icon(
              shelf.isPreset
                  ? Icons.star_border_rounded
                  : Icons.folder_outlined,
              size: 20,
              color: disabled
                  ? dimColor
                  : isDark
                  ? Colors.white60
                  : Colors.black54,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                shelf.name,
                style: TextStyle(
                  fontSize: 14,
                  color: disabled ? dimColor : textColor,
                ),
              ),
            ),
            // 数量
            Text(
              '${BookshelfService().countInShelf(shelf.id)}',
              style: TextStyle(
                fontSize: 12,
                color: disabled
                    ? dimColor
                    : isDark
                    ? Colors.white38
                    : Colors.black38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
