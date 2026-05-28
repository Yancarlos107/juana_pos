class NoveltyModel {
  final int id;
  final String name;
  final String icon;

  NoveltyModel({
    required this.id,
    required this.name,
    required this.icon,
  });

  factory NoveltyModel.fromJson(Map<String, dynamic> json) {
    return NoveltyModel(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      icon: json['icon']?.toString() ?? 'help_outline',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'icon': icon,
    };
  }
}
