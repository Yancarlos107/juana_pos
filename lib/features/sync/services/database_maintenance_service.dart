import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/storage/local_storage_repository.dart';

class DatabaseMaintenanceService {
  static const int _daysToKeepDb = 3;
  static const int _daysToKeepBackup = 7;
  static const String _backupPrefix = 'tramas_backup_';

  static Future<void> runMaintenance(LocalStorageRepository storage) async {
    try {
      final now = DateTime.now();
      final lastCleanup = await storage.getLastDbCleanupDate();

      // Limpiar backups viejos (> 7 días) sin importar si toca borrar DB hoy
      await _deleteOldBackups();

      // Si nunca se ha hecho limpieza, guardamos la fecha de hoy y no borramos nada aún
      if (lastCleanup == null) {
        await storage.saveLastDbCleanupDate(now);
        return;
      }

      final difference = now.difference(lastCleanup).inDays;

      if (difference >= _daysToKeepDb) {
        debugPrint('Iniciando mantenimiento de base de datos (pasaron $difference días)...');
        
        // 1. Exportar tramas a TXT
        final backupSuccess = await _exportAndBackup();

        if (backupSuccess) {
          // 2. Borrar tabla transactions
          await _clearTransactions();
          
          // 3. Actualizar fecha de última limpieza
          await storage.saveLastDbCleanupDate(now);
          debugPrint('Mantenimiento de base de datos completado.');
        } else {
          debugPrint('Error: No se pudo hacer el backup, cancelando borrado.');
        }
      }
    } catch (e) {
      debugPrint('Error en runMaintenance: $e');
    }
  }

  static Future<bool> _exportAndBackup() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final txs = await db.query('transactions');

      if (txs.isEmpty) {
        debugPrint('No hay tramas para exportar, continuando con borrado...');
        return true; 
      }

      final sb = StringBuffer();
      final nowStr = DateTime.now().toIso8601String();
      sb.writeln('=== EXPORTACIÓN AUTOMÁTICA DE TRAMAS ===');
      sb.writeln('Fecha: $nowStr');
      sb.writeln('Total registros: ${txs.length}');
      sb.writeln('=========================================\n');

      for (final tx in txs) {
        sb.writeln(jsonEncode(tx));
      }

      final appDir = await getApplicationDocumentsDirectory();
      final dateSlug = nowStr.split('T')[0]; // YYYY-MM-DD
      final file = File('${appDir.path}/$_backupPrefix$dateSlug.txt');
      
      await file.writeAsString(sb.toString());
      debugPrint('Backup creado en: ${file.path}');
      return true;
    } catch (e) {
      debugPrint('Error al exportar tramas: $e');
      return false;
    }
  }

  static Future<void> _clearTransactions() async {
    try {
      final db = await DatabaseHelper.instance.database;
      // Solo borramos transacciones YA confirmadas por el servidor
      // (status='synced' con server_id válido). NUNCA se borran las que siguen
      // 'pending' ni las 'synced' sin server_id (que el sync aún reenvía), para
      // no perder ventas que todavía no llegaron al backend. El backup a .txt no
      // es un respaldo válido de dinero: el criterio de borrado es "ya sincronizada",
      // no "ya pasaron 3 días".
      int count = await db.delete(
        'transactions',
        where: "status = 'synced' AND server_id IS NOT NULL AND server_id != ''",
      );
      debugPrint('Se borraron $count transacciones sincronizadas de la base de datos local.');
    } catch (e) {
      debugPrint('Error al limpiar tramas: $e');
    }
  }

  static Future<void> _deleteOldBackups() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      
      if (appDir.existsSync()) {
        final List<FileSystemEntity> entities = appDir.listSync();
        
        for (var entity in entities) {
          if (entity is File) {
            final fileName = entity.uri.pathSegments.last;
            if (fileName.startsWith(_backupPrefix)) {
              final stat = entity.statSync();
              final difference = now.difference(stat.modified).inDays;
              
              if (difference > _daysToKeepBackup) {
                entity.deleteSync();
                debugPrint('Backup antiguo eliminado: $fileName (>$difference días)');
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error al eliminar backups viejos: $e');
    }
  }
}
