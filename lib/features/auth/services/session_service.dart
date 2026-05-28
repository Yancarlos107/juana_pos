import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/database_helper.dart';

final sessionServiceProvider = Provider<SessionService>((ref) {
  return SessionService();
});

class SessionService {
  /// Valida y abre sesión de caja
  Future<void> validateAndOpenSession(int branchId) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();
    final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    // Buscar si hay alguna sesión abierta
    final openSessions = await db.query(
      'sessions',
      where: 'status = ? AND branch_id = ?',
      whereArgs: ['open', branchId],
    );

    if (openSessions.isNotEmpty) {
      for (var session in openSessions) {
        final openedAtStr = session['opened_at'] as String;
        final openedDate = DateTime.parse(openedAtStr);
        final openedDateStr = "${openedDate.year}-${openedDate.month.toString().padLeft(2, '0')}-${openedDate.day.toString().padLeft(2, '0')}";

        if (openedDateStr != todayStr) {
          // Es de otro día: Cierre forzado / tardío
          await db.update(
            'sessions',
            {
              'status': 'late_closed',
              'closed_at': now.toIso8601String(),
              'is_late': 1,
            },
            where: 'id = ?',
            whereArgs: [session['id']],
          );
        } else {
          // Hay una sesión del mismo día abierta, continuamos operando con ella
          return;
        }
      }
    }

    // Si llegamos aquí, no hay sesión abierta del día de hoy, creamos una
    await db.insert('sessions', {
      'branch_id': branchId,
      'opened_at': now.toIso8601String(),
      'status': 'open',
      'is_late': 0,
    });
  }

  /// Cierra la sesión activa normalmente
  Future<void> closeSession(int branchId) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();

    await db.update(
      'sessions',
      {
        'status': 'closed',
        'closed_at': now.toIso8601String(),
      },
      where: 'status = ?',
      whereArgs: ['open'],
    );
  }
}
