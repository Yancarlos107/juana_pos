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
    // 'json' aquí es el objeto 'data' de la respuesta
    final userMap = json['user'] as Map<String, dynamic>? ?? {};
    final branchMap = json['branch'] as Map<String, dynamic>? ?? {};
    final rolesList = json['roles'] as List? ?? [];

    // Extraer balance: data/branch/account/cards[0]/balance
    double balance = 0.0;
    try {
      final account = branchMap['account'] as Map<String, dynamic>?;
      if (account != null) {
        final cards = account['cards'] as List? ?? [];
        if (cards.isNotEmpty) {
          balance = double.tryParse(cards[0]['balance']?.toString() ?? '0') ?? 0.0;
        }
      }
    } catch (_) {}
    
    return UserModel(
      id: int.tryParse(userMap['id']?.toString() ?? '0') ?? 0,
      name: userMap['name']?.toString() ?? 'Usuario',
      email: userMap['email']?.toString() ?? '',
      branchId: int.tryParse(branchMap['id']?.toString() ?? '0') ?? 0,
      branchName: branchMap['name']?.toString() ?? 'Sucursal Valliu',
      initialBalance: balance,
      roles: rolesList.map((r) => r['name']?.toString() ?? '').where((s) => s.isNotEmpty).toList(),
    );
  }
}
