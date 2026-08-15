/// 去白边参数（不含名称，描述当前生效的一组参数）
class TrimParams {
  /// 白边阈值，0-255，亮度高于该值视为白边
  final int threshold;

  /// 保留边距（像素），裁剪后四周额外保留的像素数，0-50
  final int padding;

  /// 图片放大百分比，100=原尺寸，100-300
  final int zoom;

  /// 设备屏幕宽度（物理像素），用于放大上限约束
  final int deviceWidth;

  /// 设备屏幕高度（物理像素）
  final int deviceHeight;

  const TrimParams({
    required this.threshold,
    required this.padding,
    required this.zoom,
    required this.deviceWidth,
    required this.deviceHeight,
  });

  /// 默认参数（阈值 245，无边距，不放大，分辨率占位）
  factory TrimParams.defaultWithDevice(int width, int height) => TrimParams(
        threshold: 220,
        padding: 0,
        zoom: 100,
        deviceWidth: width,
        deviceHeight: height,
      );

  TrimParams copyWith({
    int? threshold,
    int? padding,
    int? zoom,
    int? deviceWidth,
    int? deviceHeight,
  }) {
    return TrimParams(
      threshold: threshold ?? this.threshold,
      padding: padding ?? this.padding,
      zoom: zoom ?? this.zoom,
      deviceWidth: deviceWidth ?? this.deviceWidth,
      deviceHeight: deviceHeight ?? this.deviceHeight,
    );
  }

  Map<String, dynamic> toJson() => {
        'threshold': threshold,
        'padding': padding,
        'zoom': zoom,
        'deviceWidth': deviceWidth,
        'deviceHeight': deviceHeight,
      };

  factory TrimParams.fromJson(Map<String, dynamic> json) => TrimParams(
        threshold: (json['threshold'] as num).toInt(),
        padding: (json['padding'] as num).toInt(),
        zoom: (json['zoom'] as num).toInt(),
        deviceWidth: (json['deviceWidth'] as num).toInt(),
        deviceHeight: (json['deviceHeight'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrimParams &&
          runtimeType == other.runtimeType &&
          threshold == other.threshold &&
          padding == other.padding &&
          zoom == other.zoom &&
          deviceWidth == other.deviceWidth &&
          deviceHeight == other.deviceHeight;

  @override
  int get hashCode => Object.hash(
        threshold,
        padding,
        zoom,
        deviceWidth,
        deviceHeight,
      );
}

/// 去白边预设（带名称的参数组合，可持久化保存）
class TrimPreset {
  final String name;
  final TrimParams params;

  const TrimPreset({required this.name, required this.params});

  int get threshold => params.threshold;
  int get padding => params.padding;
  int get zoom => params.zoom;
  int get deviceWidth => params.deviceWidth;
  int get deviceHeight => params.deviceHeight;

  Map<String, dynamic> toJson() => {
        'name': name,
        ...params.toJson(),
      };

  factory TrimPreset.fromJson(Map<String, dynamic> json) => TrimPreset(
        name: json['name'] as String,
        params: TrimParams.fromJson(json),
      );

  TrimPreset copyWith({
    String? name,
    TrimParams? params,
  }) {
    return TrimPreset(
      name: name ?? this.name,
      params: params ?? this.params,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrimPreset &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          params == other.params;

  @override
  int get hashCode => Object.hash(name, params);
}
