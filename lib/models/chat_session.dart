/// 已保存的 AI 对话会话（历史对话记录）。
/// 以 JSON Map 形式存入 Hive 动态 Box（'chats'），无需 TypeAdapter；
/// 消息 Map 的字段与对话页 _ChatMessage 一一对应（转换在 screen 侧完成）。
class ChatSessionData {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime savedAt;
  final String? selectedModel;
  final List<Map<String, dynamic>> messages;

  ChatSessionData({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.savedAt,
    this.selectedModel,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'savedAt': savedAt.toIso8601String(),
        'selectedModel': selectedModel,
        'messages': messages,
      };

  factory ChatSessionData.fromJson(Map<String, dynamic> json) => ChatSessionData(
        id: json['id']?.toString() ?? '',
        title: (json['title'] as String?) ?? '未命名对话',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
        savedAt:
            DateTime.tryParse(json['savedAt']?.toString() ?? '') ?? DateTime.now(),
        selectedModel: json['selectedModel'] as String?,
        messages: ((json['messages'] as List?) ?? const [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(),
      );
}
