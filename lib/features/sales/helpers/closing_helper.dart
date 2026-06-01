import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import '../providers/sales_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../auth/providers/auth_providers.dart';
import '../../auth/services/session_service.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/database/database_helper.dart';
import '../models/tarifa_model.dart';
import '../../monitoring/services/system_status_service.dart';
import '../../sync/services/background_sync_service.dart';

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

  static void showClosingConfirmation(BuildContext context, WidgetRef ref, {bool isLogout = false}) {
    final state = ref.read(salesHistoryProvider);
    final unclosedSales =
        state.sales.where((s) => s['is_closed'] != true).toList();
    
    if (unclosedSales.isEmpty) {
      if (isLogout) {
        _executeLogout(context, ref);
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
      builder: (ctx) => AlertDialog(
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

              _performClosing(context, ref, isLogout);
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
      ),
    );
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

  static Future<void> _performClosing(BuildContext context, WidgetRef ref, bool isLogout) async {
    final state = ref.read(salesHistoryProvider);
    final unclosedSales =
        state.sales.where((s) => s['is_closed'] != true).toList();
    if (unclosedSales.isEmpty) {
      if (isLogout) _executeLogout(context, ref);
      return;
    }

    final db = await DatabaseHelper.instance.database;
    final cashierName = ref.read(authProvider).user?.email ?? 'Operador';

    final sessionRows = await db.query('sessions', where: 'status = ?', whereArgs: ['open']);
    String startTimeLabel = 'Inicio de turno';
    if (sessionRows.isNotEmpty) {
      final openedAtStr = sessionRows.first['opened_at'] as String;
      final openedDate = DateTime.tryParse(openedAtStr)?.toLocal();
      if (openedDate != null) {
        startTimeLabel = '${openedDate.day.toString().padLeft(2, '0')}/${openedDate.month.toString().padLeft(2, '0')}/${openedDate.year} ${openedDate.hour.toString().padLeft(2, '0')}:${openedDate.minute.toString().padLeft(2, '0')}:${openedDate.second.toString().padLeft(2, '0')}';
      }
    }

    final user = ref.read(authProvider).user;
    final storage = ref.read(localStorageProvider);
    final posName = await storage.getPosLocationName();
    final branchName = posName ?? user?.branchName ?? 'Sucursal Juana';
    final branchId = user?.branchId ?? 0;

    double totalAmount = 0;
    Map<String, int> breakdownQty = {};
    Map<String, double> breakdownTotal = {};

    int pmrCount = 0;
    int reprintsCount = 0;
    List<String> pmrHours = [];

    for (final sale in unclosedSales) {
      if (sale['product_id'] == 'CIERRE DE CAJA') continue;
      if (sale['print_status'] == 2) {
        reprintsCount++;
      }
      if (sale['product_id'] == 'PMR') {
        pmrCount++;
        final dt = DateTime.tryParse(sale['created_at'].toString())?.toLocal();
        if (dt != null) {
          pmrHours.add(
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}');
        }
        continue;
      }
      final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
      final productId = sale['product_id']?.toString() ?? 'Desc.';
      totalAmount += amount;
      breakdownQty[productId] = (breakdownQty[productId] ?? 0) + 1;
      breakdownTotal[productId] = (breakdownTotal[productId] ?? 0) + amount;
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

    final jsonStr = jsonEncode({
      "c": cashierName,
      "b": branchId,
      "a": totalAmount,
      "q": unclosedSales.length - pmrCount,
      "pmr_q": pmrCount,
      "d": dateStr,
      "t": timeStr,
      "v": "v2"
    });

    final qrData = base64Encode(utf8.encode(jsonStr));

    // Mostrar loader
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()));

    // Imprimir — null = permiso USB pendiente (Epson)
    final printer = ref.read(printerServiceProvider);
    final printResult = await printer.printClosingTicket(
      cashierName: cashierName,
      branchName: branchName,
      totalTransactions: unclosedSales.length - pmrCount,
      totalAmount: totalAmount,
      startTime: startTimeLabel,
      endTime: closingLabel,
      qrData: qrData,
      breakdown: breakdownLines,
      pmrCount: pmrCount,
      pmrHours: pmrHours,
      reprintsCount: reprintsCount,
    );

    if (printResult == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Acepta el permiso USB e intenta el cierre de nuevo'),
          backgroundColor: Colors.orange));
      Navigator.pop(context);
      return;
    }
    final printSuccess = printResult ?? false;

    if (context.mounted) Navigator.pop(context); // Quitar loader

    try {
      final db = await DatabaseHelper.instance.database;
      final sessionQuery = await db.query('sessions', where: 'status = ?', whereArgs: ['open']);
      final int? sessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] as int : null;

      final currentCashierId = ref.read(authProvider).user?.id ?? 1;

      await db.insert('transactions', {
        'id': 'closure-${now.millisecondsSinceEpoch}',
        'session_id': sessionId,
        'cashier_id': currentCashierId,
        'product_id': 'CIERRE DE CAJA',
        'amount': totalAmount,
        'pmr': 0,
        'status': 'pending',
        'created_at': now.toIso8601String(),
        'qr_data': qrData,
        'print_status': printSuccess ? 1 : 0,
      });

      await ref.read(sessionServiceProvider).closeSession(branchId);

      if (isLogout) {
        _executeLogout(context, ref);
      } else {
        ref.read(salesHistoryProvider.notifier).fetchHistory();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error al cerrar caja: ${e.toString()}'),
            backgroundColor: Colors.redAccent));
      }
    }

    if (!printSuccess) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo imprimir el cierre'),
            backgroundColor: Colors.orange));
      }
    }
  }

  static void _executeLogout(BuildContext context, WidgetRef ref) async {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()));
        
    try {
      await ref.read(backgroundSyncProvider).syncPendingData().timeout(const Duration(seconds: 3));
    } catch (_) {}

    await ref.read(authProvider.notifier).logout();
    if (context.mounted) {
      Navigator.pop(context);
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }
}
