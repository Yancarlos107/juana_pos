class PosLocationModel {
  final int id;
  final String name;
  final int companyId;
  final bool isActive;

  PosLocationModel({
    required this.id,
    required this.name,
    required this.companyId,
    required this.isActive,
  });

  factory PosLocationModel.fromJson(Map<String, dynamic> json) {
    return PosLocationModel(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      companyId: json['company_id'] as int? ?? 0,
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'company_id': companyId,
      'is_active': isActive,
    };
  }
}
