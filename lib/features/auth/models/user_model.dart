/// Modelo que representa al usuario autenticado en el POS.
class UserModel {
  final int id;
  final String name;
  final String email;
  final int branchId;
  final String branchName;
  final double initialBalance;
  final List<String> roles;

  UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.branchId,
    required this.branchName,
    required this.initialBalance,
    required this.roles,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    final userMap = json['user'] as Map<String, dynamic>? ?? {};
    final cashierMap = json['cashier'] as Map<String, dynamic>? ?? {};
    final branchMap = json['branch'] as Map<String, dynamic>? ?? {};
    // Los roles ya no vienen en cashier-login, así que por defecto es cashier
    final rolesList = json['roles'] as List? ?? ['cashier'];

    return UserModel(
      id: int.tryParse(userMap['id']?.toString() ?? '0') ?? 0,
      name: userMap['name']?.toString() ??
          cashierMap['name']?.toString() ??
          'Cajero',
      email: userMap['phone_number']?.toString() ?? '',
      branchId: int.tryParse(branchMap['id']?.toString() ?? '0') ?? 0,
      branchName: branchMap['name']?.toString() ?? 'Sucursal Juana',
      // El saldo inicial se obtiene luego a través del endpoint my-cards
      initialBalance: 0.0,
      roles: rolesList
          .map((r) {
            if (r is Map) return r['name']?.toString() ?? '';
            return r.toString();
          })
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }
}
