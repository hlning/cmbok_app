import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 设备边框预览组件
///
/// 模拟手机屏幕内图片的显示效果，只显示去白边后的图片。
/// 左右箭头浮在屏幕两侧用于切换预览图，底部显示页码。
class DeviceFramePreview extends StatelessWidget {
  /// 去白边后的图片字节
  final Uint8List? imageBytes;

  /// 设备宽度（物理像素，用于计算比例）
  final int deviceWidth;

  /// 设备高度（物理像素）
  final int deviceHeight;

  /// 左箭头回调
  final VoidCallback? onPrev;

  /// 右箭头回调
  final VoidCallback? onNext;

  /// 页码指示文本，如 "1/3"
  final String pageIndicator;

  /// 是否加载中
  final bool isLoading;

  const DeviceFramePreview({
    super.key,
    required this.imageBytes,
    required this.deviceWidth,
    required this.deviceHeight,
    this.onPrev,
    this.onNext,
    this.pageIndicator = '',
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final frameColor = isDark ? Colors.white12 : Colors.black12;
    final bezelWidth = 6.0;

    return AspectRatio(
      aspectRatio: deviceWidth > 0 && deviceHeight > 0
          ? deviceWidth / deviceHeight
          : 9 / 16,
      child: Container(
        decoration: BoxDecoration(
          color: frameColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: frameColor, width: bezelWidth),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 屏幕区域
              Container(color: Colors.black),

              // 图片
              if (imageBytes != null) _buildImage(),

              // 加载中
              if (isLoading)
                const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),

              // 左箭头
              Positioned(
                left: 2,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton(
                    icon: const Icon(Icons.chevron_left,
                        color: Colors.white, size: 28),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black38,
                      padding: const EdgeInsets.all(4),
                    ),
                    onPressed: onPrev,
                  ),
                ),
              ),

              // 右箭头
              Positioned(
                right: 2,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton(
                    icon: const Icon(Icons.chevron_right,
                        color: Colors.white, size: 28),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black38,
                      padding: const EdgeInsets.all(4),
                    ),
                    onPressed: onNext,
                  ),
                ),
              ),

              // 页码
              if (pageIndicator.isNotEmpty)
                Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        pageIndicator,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Image.memory(
          imageBytes!,
          fit: BoxFit.contain,
          alignment: Alignment.center,
          gaplessPlayback: true,
        );
      },
    );
  }
}
