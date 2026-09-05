import 'package:yaml/yaml.dart';

/// shiguang_warehouse 仓库索引中的学校条目（对应 index/root_index.yaml）。
class ShiguangSchool {
  final String id; // 唯一标识（如 "CQU"）
  final String name; // 中文名称（如 "重庆大学"）
  final String initial; // 名称首字母（用于分组排序）
  final String resourceFolder; // 资源文件夹名称

  const ShiguangSchool({
    required this.id,
    required this.name,
    required this.initial,
    required this.resourceFolder,
  });

  /// 通用教务系统 / 通用工具条目（不属于具体学校，索引前 5 条固定）。
  bool get isGeneric => genericFolderIds.contains(id);

  factory ShiguangSchool.fromYaml(dynamic node) {
    final map = node as YamlMap? ?? const {};
    return ShiguangSchool(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '未命名',
      initial: map['initial']?.toString() ?? '#',
      resourceFolder: map['resource_folder']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'initial': initial,
        'resource_folder': resourceFolder,
      };

  factory ShiguangSchool.fromJson(Map<String, dynamic> json) => ShiguangSchool(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '未命名',
        initial: json['initial']?.toString() ?? '#',
        resourceFolder: json['resource_folder']?.toString() ?? '',
      );
}

/// 索引前 5 条固定为通用条目：通用工具 + 四大通用教务系统。
const Set<String> genericFolderIds = {
  'GLOBAL_TOOLS',
  'zhengfang_jiaowu',
  'chaoxing_jiaowu',
  'qingguo_jiaowu',
  'urp_jiaowu',
};

/// 适配器分类（对应 adapters.yaml 的 category 字段）。
enum ShiguangAdapterCategory {
  bachelor, // 本科/专科
  postgraduate, // 研究生
  generalTool, // 通用工具
  unknown;

  String get label {
    switch (this) {
      case ShiguangAdapterCategory.bachelor:
        return '本科/专科';
      case ShiguangAdapterCategory.postgraduate:
        return '研究生';
      case ShiguangAdapterCategory.generalTool:
        return '通用工具';
      case ShiguangAdapterCategory.unknown:
        return '其他';
    }
  }

  static ShiguangAdapterCategory fromString(String? raw) {
    switch (raw) {
      case 'BACHELOR_AND_ASSOCIATE':
        return ShiguangAdapterCategory.bachelor;
      case 'POSTGRADUATE':
        return ShiguangAdapterCategory.postgraduate;
      case 'GENERAL_TOOL':
        return ShiguangAdapterCategory.generalTool;
      default:
        return ShiguangAdapterCategory.unknown;
    }
  }
}

/// 单个适配器条目（对应 resources/<folder>/adapters.yaml 中的一项）。
class ShiguangAdapter {
  final String adapterId;
  final String adapterName;
  final ShiguangAdapterCategory category;
  final String assetJsPath; // 适配脚本相对路径
  final String importUrl; // 教务系统登录 URL（可为空）
  final String maintainer;
  final String description;

  const ShiguangAdapter({
    required this.adapterId,
    required this.adapterName,
    required this.category,
    required this.assetJsPath,
    required this.importUrl,
    required this.maintainer,
    required this.description,
  });

  factory ShiguangAdapter.fromYaml(dynamic node) {
    final map = node as YamlMap? ?? const {};
    return ShiguangAdapter(
      adapterId: map['adapter_id']?.toString() ?? '',
      adapterName: map['adapter_name']?.toString() ?? '未命名适配器',
      category: ShiguangAdapterCategory.fromString(map['category']?.toString()),
      assetJsPath: map['asset_js_path']?.toString() ?? '',
      importUrl: map['import_url']?.toString() ?? '',
      maintainer: map['maintainer']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'adapter_id': adapterId,
        'adapter_name': adapterName,
        'category': category.name,
        'asset_js_path': assetJsPath,
        'import_url': importUrl,
        'maintainer': maintainer,
        'description': description,
      };

  factory ShiguangAdapter.fromJson(Map<String, dynamic> json) =>
      ShiguangAdapter(
        adapterId: json['adapter_id']?.toString() ?? '',
        adapterName: json['adapter_name']?.toString() ?? '未命名适配器',
        category:
            ShiguangAdapterCategory.fromString(json['category']?.toString()),
        assetJsPath: json['asset_js_path']?.toString() ?? '',
        importUrl: json['import_url']?.toString() ?? '',
        maintainer: json['maintainer']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
      );
}
