import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:math' as math;
import '../../../main.dart';
import '../providers/sales_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../auth/providers/auth_providers.dart';
import '../../auth/services/session_service.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/network/dio_client.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/device_utils.dart';
import '../models/tarifa_model.dart';
import '../../monitoring/services/system_status_service.dart';
import '../../sync/services/background_sync_service.dart';
import '../../../core/utils/print_log_helper.dart';

class ClosingHelper {
  static String formatCurrency(double value) {
    final hasDecimals = value % 1 != 0;
    if (hasDecimals) {
      final parts = value.toStringAsFixed(2).split('.');
      final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
      return '$intPart.${parts[1]}';
    } else {
      return value.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
  }

  static Future<double> getUnclosedTotal(WidgetRef ref) async {
    final db = await DatabaseHelper.instance.database;
    final storage = ref.read(localStorageProvider);
    final branchId = await storage.getBranchId() ?? 0;
    
    final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
    if (sessionQuery.isEmpty) return 0;

    final currentCashierId = ref.read(authProvider).user?.id ?? 1;
    final sessionId = sessionQuery.first['id'] as int;
    final unclosedSales = await db.query(
      'transactions', 
      where: 'session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id != ? AND product_id != ?', 
      whereArgs: [sessionId, currentCashierId, 'CIERRE DE CAJA', 'APERTURA DE CAJA']
    );

    double totalAmount = 0;
    for (final sale in unclosedSales) {
      if (sale['product_id'] == 'PMR') continue;
      final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
      totalAmount += amount;
    }
    return totalAmount;
  }

  static void showEmptySalesModal(BuildContext context, {VoidCallback? onClose}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        Future.delayed(const Duration(seconds: 3), () {
          if (ctx.mounted && Navigator.canPop(ctx)) {
            Navigator.pop(ctx);
            if (onClose != null) {
              onClose();
            }
          }
        });
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.orange, width: 3),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline_rounded, color: Colors.orange, size: 60),
                SizedBox(height: 16),
                Text(
                  'NO HAY VENTAS PARA HACER UN CIERRE DE CAJA',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.black87),
                ),
                SizedBox(height: 16),
                Text(
                  'CONTINÚA CON EL CIERRE DE SESIÓN NORMAL',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                ),
              ],
            ),
          ),
        );
      }
    );
  }

  /// Construye el RESUMEN DEL DIA (consolidado "arrastre") a partir de todas
  /// las transacciones de la sesión, igual que en el Cierre de Caja.
  static Future<Map<String, dynamic>> _buildDaySummary(
    Database db,
    int sessionId,
    ProductsState productsState, {
    dynamic cashList,
    double? cash,
    double? balance,
  }) async {
    final allSalesAgg = await db.rawQuery('''
      SELECT product_id, COUNT(*) as qty, SUM(amount) as total_amount
      FROM transactions
      WHERE session_id = ? AND product_id NOT IN ('CIERRE DE CAJA', 'APERTURA DE CAJA', 'INGRESO_FISCALIZADOR', 'PMR')
      GROUP BY product_id
    ''', [sessionId]);

    int dayCount = 0;
    double dayTotalAmount = 0;
    Map<String, int> dayBreakdownQty = {};
    Map<String, double> dayBreakdownTotal = {};

    for (final row in allSalesAgg) {
      final productId = row['product_id']?.toString() ?? 'Desc.';
      final qty = (row['qty'] as num?)?.toInt() ?? 0;
      final total = (row['total_amount'] as num?)?.toDouble() ?? 0.0;
      
      dayCount += qty;
      dayTotalAmount += total;
      dayBreakdownQty[productId] = qty;
      dayBreakdownTotal[productId] = total;
    }

    List<String> dayBreakdownLines = [];
    dayBreakdownQty.forEach((pId, qty) {
      final prod = productsState.products.firstWhere((p) => p.id == pId,
          orElse: () => Product(id: pId, productName: 'Tarifa $pId', value: 0));
      final t = dayBreakdownTotal[pId] ?? 0;
      final qtyStr = '${qty}x'.padRight(4);
      final nameStr = prod.productName.length > 15
          ? prod.productName.substring(0, 15)
          : prod.productName.padRight(15);
      final valStr = '\$${formatCurrency(t)}'.padLeft(8);
      dayBreakdownLines.add('$qtyStr $nameStr $valStr');
    });

    final daySummary = <String, dynamic>{
      'totalTransactions': dayCount,
      'totalAmount': dayTotalAmount,
      'breakdown': dayBreakdownLines,
    };

    if (cashList != null && cash != null && balance != null) {
      daySummary['balance'] = balance;
    }

    return daySummary;
  }

  static Future<void> printArqueoTicket(BuildContext context, WidgetRef ref) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    try {
      final db = await DatabaseHelper.instance.database;
      final storage = ref.read(localStorageProvider);
      final branchId = await storage.getBranchId() ?? 0;

      final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
      if (sessionQuery.isEmpty) {
        if (context.mounted) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay sesión abierta.')));
        return;
      }

      final currentCashierId = ref.read(authProvider).user?.id ?? 1;
      final sessionId = sessionQuery.first['id'] as int;
      final unclosedCountResult = await db.rawQuery('''
        SELECT COUNT(*) as c 
        FROM transactions 
        WHERE session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id NOT IN ('CIERRE DE CAJA', 'APERTURA DE CAJA')
      ''', [sessionId, currentCashierId]);
      
      final totalUnclosedCount = (unclosedCountResult.first['c'] as int?) ?? 0;

      if (totalUnclosedCount == 0) {
        if (context.mounted) {
          Navigator.pop(context); // Cerrar loader
          showEmptySalesModal(context);
        }
        return;
      }

      final unclosedAgg = await db.rawQuery('''
        SELECT product_id, COUNT(*) as qty, SUM(amount) as total_amount
        FROM transactions
        WHERE session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id NOT IN ('CIERRE DE CAJA', 'APERTURA DE CAJA', 'PMR')
        GROUP BY product_id
      ''', [sessionId, currentCashierId]);

      double totalAmount = 0;
      Map<String, int> breakdownQty = {};

      for (final row in unclosedAgg) {
        final productId = row['product_id']?.toString() ?? 'Desc.';
        final qty = (row['qty'] as num?)?.toInt() ?? 0;
        final total = (row['total_amount'] as num?)?.toDouble() ?? 0.0;
        
        totalAmount += total;
        breakdownQty[productId] = qty;
      }

      final productsState = ref.read(productsProvider);
      List<Map<String, dynamic>> productList = [];

      breakdownQty.forEach((pId, qty) {
        final prod = productsState.products.firstWhere((p) => p.id == pId,
            orElse: () => Product(id: pId, productName: 'Tarifa $pId', value: 0));
        productList.add({
          'qty': qty,
          'name': prod.productName,
          'total': qty * prod.value
        });
      });

      final cashierName = ref.read(authProvider).user?.name ?? 'Operador';
      final reviewerName = ref.read(reviewerNameProvider);
      if (context.mounted) Navigator.pop(context); // Cerrar loader ANTES del diálogo de confirmación

      if (!context.mounted) return;

      bool isArrastre = false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                title: const Row(
                  children: [
                    Icon(Icons.fact_check_rounded, color: Colors.blueGrey),
                    SizedBox(width: 10),
                    Text('Arqueo de Caja', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('¿Deseas imprimir el arqueo de caja?', style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text('Arrastre', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      subtitle: const Text('Imprime el consolidado global de todo el día', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      value: isArrastre,
                      activeColor: const Color(0xFF6642F8),
                      onChanged: (val) {
                        setState(() {
                          isArrastre = val;
                        });
                      },
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text('CANCELAR', style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(ctx, true),
                    icon: const Icon(Icons.print_rounded, size: 20),
                    label: const Text('IMPRIMIR', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );

      if (confirmed != true) return;

      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Color(0xFF6642F8))),
        );
      }

      final isPrinterConnected = await ref.read(systemStatusProvider.notifier).checkPrinterNow();
      if (!isPrinterConnected) {
        if (context.mounted) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Impresora no conectada.')));
        return;
      }

      final posName = await storage.getPosLocationName();
      final branchName = posName ?? ref.read(authProvider).user?.branchName ?? 'Sucursal Juana';

      Map<String, dynamic>? daySummary;
      if (isArrastre) {
        daySummary = await _buildDaySummary(db, sessionId, productsState);
      }

      if (context.mounted) Navigator.pop(context); // Cerrar loader antes de imprimir

      final printResult = await ref.read(printerServiceProvider).printArqueoTicket(
        totalAmount: totalAmount,
        products: productList,
        cashierName: cashierName,
        reviewerName: reviewerName,
        branchName: branchName,
        daySummary: daySummary,
      );

      if (context.mounted) {
        if (printResult == true) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Arqueo impreso con éxito.')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Arqueo completado (sin impresión).')));
        }
      }
      navigatorKey.currentState?.pushNamedAndRemoveUntil('/dashboard', (route) => false);
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  static Future<void> showClosingConfirmation(BuildContext context, WidgetRef ref, {bool isLogout = false}) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    final db = await DatabaseHelper.instance.database;
    final storage = ref.read(localStorageProvider);
    final branchId = await storage.getBranchId() ?? 0;
    
    final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
    
    if (context.mounted) Navigator.pop(context); // Cerrar loader
    
    if (sessionQuery.isEmpty) {
      if (isLogout) {
        _executeLogout(context, ref);
      }
      return;
    }

    final currentCashierId = ref.read(authProvider).user?.id ?? 1;
    final sessionId = sessionQuery.first['id'] as int;
    final unclosedSales = await db.query(
      'transactions', 
      where: 'session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id != ? AND product_id != ?', 
      whereArgs: [sessionId, currentCashierId, 'CIERRE DE CAJA', 'APERTURA DE CAJA']
    );

    if (unclosedSales.isEmpty) {
      if (context.mounted) {
        showEmptySalesModal(context, onClose: () {
          if (isLogout && context.mounted) {
            Navigator.pop(context); // Cierra modal previo o pantalla si aplica
          }
        });
      }
      return;
    }

    double totalAmount = 0;
    Map<String, int> breakdownQty = {};
    int pmrCount = 0;
    int reprintsCount = 0;

    for (final sale in unclosedSales) {
      if (sale['print_status'] == 2) {
        reprintsCount++;
      }
      if (sale['product_id'] == 'PMR') {
        pmrCount++;
        continue;
      }
      final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
      final productId = sale['product_id']?.toString() ?? 'Desc.';
      totalAmount += amount;
      breakdownQty[productId] = (breakdownQty[productId] ?? 0) + 1;
    }

    final productsState = ref.read(productsProvider);
    List<Widget> breakdownWidgets = [];
    breakdownQty.forEach((pId, qty) {
      final prod = productsState.products.firstWhere((p) => p.id == pId,
          orElse: () => Product(id: pId, productName: 'Tarifa $pId', value: 0));
      breakdownWidgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${qty}x ${prod.productName}',
                style: const TextStyle(fontSize: 22)),
            Text('\$ ${formatCurrency(qty * prod.value)}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
          ],
        ),
      ));
    });

    showDialog(
      context: context,
      builder: (ctx) {
        bool isArrastre = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.summarize_rounded, color: isLogout ? Colors.redAccent : const Color(0xFF6642F8)),
            const SizedBox(width: 10),
            Text(isLogout ? 'Cierre antes de salir' : 'Resumen de Cierre',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                isLogout 
                  ? 'Antes de cerrar sesión debes realizar el Cierre de Caja. Se imprimirá el siguiente resumen:'
                  : '¿Estás seguro de realizar el cierre de caja? Se imprimirá el siguiente resumen:',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F7FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: [
                  ...breakdownWidgets,
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Transacciones (Ventas):',
                          style: TextStyle(color: Colors.grey, fontSize: 22)),
                      Text('${unclosedSales.length - pmrCount}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 22)),
                    ],
                  ),
                  if (pmrCount > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Aperturas PMR:',
                            style: TextStyle(color: Colors.blue, fontSize: 22)),
                        Text('$pmrCount',
                            style: const TextStyle(
                                color: Colors.blue,
                                fontWeight: FontWeight.bold,
                                fontSize: 22)),
                      ],
                    ),
                  ],
                  if (reprintsCount > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Reimpresiones:',
                            style:
                                TextStyle(color: Colors.orange, fontSize: 22)),
                        Text('$reprintsCount',
                            style: const TextStyle(
                                color: Colors.orange,
                                fontWeight: FontWeight.bold,
                                fontSize: 22)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total Recaudado:',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 28)),
                      Text('\$ ${formatCurrency(totalAmount)}',
                          style: TextStyle(
                              color: isLogout ? Colors.redAccent : const Color(0xFF6642F8),
                              fontWeight: FontWeight.w900,
                              fontSize: 38)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (ref.read(reviewerNameProvider) == null)
              SwitchListTile(
                title: const Text('Arrastre', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                subtitle: const Text('Imprime el consolidado global de todo el día', style: TextStyle(fontSize: 12, color: Colors.grey)),
                value: isArrastre,
                activeColor: const Color(0xFF6642F8),
                onChanged: (val) {
                  setState(() {
                    isArrastre = val;
                  });
                },
              ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('CANCELAR',
                  style: TextStyle(
                      color: Colors.grey.shade800, fontWeight: FontWeight.bold, fontSize: 16))),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(
                    child: CircularProgressIndicator(color: Color(0xFF6642F8))),
              );

              final isPrinterConnected = await ref
                  .read(systemStatusProvider.notifier)
                  .checkPrinterNow();

              if (context.mounted) Navigator.pop(context); // Cerrar loading

              if (!isPrinterConnected) {
                final proceed = await _showPrinterWarningDialog(context);
                if (!proceed) return;
              }

              _performClosing(context, ref, isLogout, isArrastre: isArrastre);
            },
            icon: const Icon(Icons.print_rounded, size: 20),
            label: Text(isLogout ? 'CERRAR E IMPRIMIR' : 'CONFIRMAR', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isLogout ? Colors.redAccent : const Color(0xFF6642F8),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
          ),
        ],
      ); // AlertDialog
          },
        ); // StatefulBuilder
      },
    ); // showDialog
  }

  static Future<bool> _showPrinterWarningDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.print_disabled_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Impresora Desconectada',
                style: TextStyle(
                    color: Color(0xFF3F3D56),
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ],
        ),
        content: const Text(
          'No se ha detectado la impresora térmica.\n\n¿Deseas continuar y registrar el cierre de caja sin imprimir el tiquete?',
          style: TextStyle(fontSize: 16, color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCELAR',
                style:
                    TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('CONTINUAR SIN IMPRIMIR',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // --- Nueva función para Arqueo de Caja (Pantalla de Conteo) ---
  static Future<void> performArqueoClosing(
    BuildContext context, 
    WidgetRef ref, 
    dynamic cashList, 
    double totalCash, 
    double balance, 
    {bool isLogout = false, bool isArrastre = false}
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    final isPrinterConnected = await ref.read(systemStatusProvider.notifier).checkPrinterNow();

    if (context.mounted) Navigator.pop(context); // Cerrar loading

    if (!isPrinterConnected) {
      final proceed = await _showPrinterWarningDialog(context);
      if (!proceed) return;
    }

    _performClosing(context, ref, isLogout, cashList: cashList, cash: totalCash, balance: balance, isArrastre: isArrastre);
  }

  static Future<void> _performClosing(BuildContext context, WidgetRef ref, bool isLogout, {dynamic cashList, double? cash, double? balance, bool isArrastre = false}) async {
    final db = await DatabaseHelper.instance.database;
    final storage = ref.read(localStorageProvider);
    final branchId = await storage.getBranchId() ?? 0;
    
    final sessionRows = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
    
    if (sessionRows.isEmpty) {
      if (isLogout) _executeLogout(context, ref);
      return;
    }

    final sessionId = sessionRows.first['id'] as int;
    final currentCashierId = ref.read(authProvider).user?.id ?? 1;
    try {
      final unclosedCountResult = await db.rawQuery('''
        SELECT COUNT(*) as c 
        FROM transactions 
        WHERE session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id NOT IN ('CIERRE DE CAJA', 'APERTURA DE CAJA')
      ''', [sessionId, currentCashierId]);
      
      final totalUnclosedCount = (unclosedCountResult.first['c'] as int?) ?? 0;

      if (totalUnclosedCount == 0 && !isArrastre) {
        if (context.mounted) {
          showEmptySalesModal(context, onClose: () {
            if (isLogout && context.mounted) {
              Navigator.pop(context);
            }
          });
        }
        return;
      }

      final cashierName = ref.read(authProvider).user?.name ?? 'Operador';

      String startTimeLabel = 'Inicio de turno';
      if (sessionRows.isNotEmpty) {
        final openedAtStr = sessionRows.first['opened_at'] as String;
        final openedDate = DateTime.tryParse(openedAtStr)?.toLocal();
        if (openedDate != null) {
          startTimeLabel = '${openedDate.day.toString().padLeft(2, '0')}/${openedDate.month.toString().padLeft(2, '0')}/${openedDate.year} ${openedDate.hour.toString().padLeft(2, '0')}:${openedDate.minute.toString().padLeft(2, '0')}:${openedDate.second.toString().padLeft(2, '0')}';
        }
      }

      final user = ref.read(authProvider).user;
      final posName = await storage.getPosLocationName();
      final branchName = posName ?? user?.branchName ?? 'Sucursal Juana';

      final unclosedAgg = await db.rawQuery('''
        SELECT product_id, COUNT(*) as qty, SUM(amount) as total_amount
        FROM transactions
        WHERE session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id NOT IN ('CIERRE DE CAJA', 'APERTURA DE CAJA', 'PMR')
        GROUP BY product_id
      ''', [sessionId, currentCashierId]);

      final pmrSales = await db.rawQuery('''
        SELECT created_at 
        FROM transactions 
        WHERE session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id = 'PMR'
      ''', [sessionId, currentCashierId]);
      
      final reprintsResult = await db.rawQuery('''
        SELECT COUNT(*) as c 
        FROM transactions 
        WHERE session_id = ? AND cashier_id = ? AND is_closed = 0 AND print_status = 2
      ''', [sessionId, currentCashierId]);

      double totalAmount = 0;
      Map<String, int> breakdownQty = {};
      Map<String, double> breakdownTotal = {};

      int pmrCount = pmrSales.length;
      int reprintsCount = (reprintsResult.first['c'] as int?) ?? 0;
      List<String> pmrHours = [];

      for (var sale in pmrSales) {
        final dt = DateTime.tryParse(sale['created_at'].toString())?.toLocal();
        if (dt != null) {
          pmrHours.add('${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}');
        }
      }

      for (final row in unclosedAgg) {
        final productId = row['product_id']?.toString() ?? 'Desc.';
        final qty = (row['qty'] as num?)?.toInt() ?? 0;
        final total = (row['total_amount'] as num?)?.toDouble() ?? 0.0;
        
        totalAmount += total;
        breakdownQty[productId] = qty;
        breakdownTotal[productId] = total;
      }

    final productsState = ref.read(productsProvider);
    List<String> breakdownLines = [];
    breakdownQty.forEach((pId, qty) {
      final prod = productsState.products.firstWhere((p) => p.id == pId,
          orElse: () => Product(id: pId, productName: 'Tarifa $pId', value: 0));
      final t = breakdownTotal[pId] ?? 0;
      final qtyStr = '${qty}x'.padRight(4);
      final nameStr = prod.productName.length > 15
          ? prod.productName.substring(0, 15)
          : prod.productName.padRight(15);
      final valStr = '\$${formatCurrency(t)}'.padLeft(8);
      breakdownLines.add('$qtyStr $nameStr $valStr');
    });

    final nowUtc = DateTime.now().toUtc();
    final now = nowUtc.subtract(const Duration(hours: 5));
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final closingLabel = '$dateStr $timeStr';

    final userEmail = ref.read(authProvider).user?.email ?? '01';
    final cashierCode = userEmail.split('@').first;

    final payloadMap = {
      "c": cashierName,
      "cc": cashierCode,
      "b": branchId,
      "a": totalAmount,
      "q": totalUnclosedCount - pmrCount,
      "pmr_q": pmrCount,
      "d": dateStr,
      "t": timeStr,
      "v": "v2"
    };

    if (cashList != null && cash != null && balance != null) {
      if (cashList is Map) {
        payloadMap["coins_total"] = cashList["coins_total"];
        payloadMap["bills_total"] = cashList["bills_total"];
      }
      payloadMap["cash"] = cash;
      payloadMap["balance"] = balance;
    }

    final jsonStr = jsonEncode(payloadMap);
    final qrData = base64Encode(utf8.encode(jsonStr));

    // Mostrar loader
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()));

    final posLocationId = await ref.read(localStorageProvider).getPosLocationId();

    Map<String, dynamic>? daySummary;
    if (isArrastre) {
      daySummary = await _buildDaySummary(db, sessionId, productsState,
          cashList: cashList, cash: cash, balance: balance);
    }

    if (context.mounted) Navigator.pop(context); // Quitar loader ANTES de imprimir para evitar deadlock de UI

    final isFiscalizador = ref.read(reviewerNameProvider) != null;
    bool shouldPrintBreakdown = false;
    
    if (isFiscalizador) {
      shouldPrintBreakdown = true;
    } else {
      if (cashList != null && cash != null && cash > 0) {
        shouldPrintBreakdown = true;
      }
    }

    final printer = ref.read(printerServiceProvider);
    final printResult = await printer.printClosingTicket(
      cashierName: cashierName,
      cashierId: cashierCode,
      branchName: branchName,
      posLocationId: posLocationId,
      totalTransactions: totalUnclosedCount - pmrCount,
      totalAmount: totalAmount,
      startTime: startTimeLabel,
      endTime: closingLabel,
      qrData: qrData,
      breakdown: shouldPrintBreakdown ? breakdownLines : null,
      pmrCount: pmrCount,
      pmrHours: pmrHours,
      reprintsCount: reprintsCount,
      cashList: cashList,
      cash: cash,
      balance: balance,
      daySummary: daySummary,
    );

    if (printResult == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Acepta el permiso USB e intenta el cierre de nuevo'),
          backgroundColor: Colors.orange));
      return;
    }
    final printSuccess = printResult ?? false;

    final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
    final int? currentSessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] as int : null;

    final random = math.Random();
    final plotIdBytes = List<int>.generate(16, (i) => random.nextInt(256));
    final plotId = md5.convert(plotIdBytes).toString();
    final macAddress = await DeviceUtils.getMacAddress();

    await db.transaction((txn) async {
      await txn.insert('transactions', {
        'id': 'closure-${now.millisecondsSinceEpoch}',
        'session_id': currentSessionId,
        'cashier_id': currentCashierId,
        'pos_location_id': posLocationId,
        'product_id': 'CIERRE DE CAJA',
        'amount': totalAmount,
        'pmr': 0,
        'status': 'pending',
        'created_at': now.toIso8601String(),
        'qr_data': qrData,
        'print_status': printSuccess ? 1 : 0,
        'is_closed': 1,
        'plot_id': plotId,
        'mac_address': macAddress,
      });

      await txn.update(
        'transactions',
        {'is_closed': 1},
        where: '(session_id = ? OR (? IS NULL AND session_id IS NULL)) AND cashier_id = ? AND is_closed = 0 AND product_id != ?',
        whereArgs: [currentSessionId, currentSessionId, currentCashierId, 'CIERRE DE CAJA'],
      );
    });

    if (isLogout) {
      _executeLogout(context, ref);
    } else {
      ref.read(salesHistoryProvider.notifier).fetchHistory();
    }

    await PrintLogHelper.logClosure();

    if (!printSuccess) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo imprimir el cierre'),
            backgroundColor: Colors.orange));
      }
    }
  } catch (e) {
    if (context.mounted) {
      // Ensure any lingering loader is popped
      Navigator.of(context).popUntil((route) => route.isFirst || route.settings.name == '/recaudo' || route.settings.name == '/dashboard');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error inesperado al cerrar caja: ${e.toString()}'),
          backgroundColor: Colors.redAccent));
    }
  }
}

  static void _executeLogout(BuildContext context, WidgetRef ref) async {
    final navContext = navigatorKey.currentContext ?? context;
    if (!navContext.mounted) return;

    showDialog(
        context: navContext,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()));
        
    try {
      await ref.read(backgroundSyncProvider).syncPendingData().timeout(const Duration(seconds: 3));
    } catch (_) {}

    ref.read(reviewerNameProvider.notifier).state = null;
    await ref.read(authProvider.notifier).logout(ref);
    
    navigatorKey.currentState?.pop(); // close loader
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (route) => false);
  }
}
