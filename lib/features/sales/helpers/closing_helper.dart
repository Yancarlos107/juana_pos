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
      final unclosedSales = await db.query(
        'transactions', 
        where: 'session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id != ? AND product_id != ?', 
        whereArgs: [sessionId, currentCashierId, 'CIERRE DE CAJA', 'APERTURA DE CAJA']
      );

      if (unclosedSales.isEmpty) {
        if (context.mounted) {
          Navigator.pop(context); // Cerrar loader
          showEmptySalesModal(context);
        }
        return;
      }

      double totalAmount = 0;
      Map<String, int> breakdownQty = {};

      for (final sale in unclosedSales) {
        if (sale['product_id'] == 'PMR') continue;
        final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
        final productId = sale['product_id']?.toString() ?? 'Desc.';
        totalAmount += amount;
        breakdownQty[productId] = (breakdownQty[productId] ?? 0) + 1;
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

      final isPrinterConnected = await ref.read(systemStatusProvider.notifier).checkPrinterNow();
      if (!isPrinterConnected) {
        if (context.mounted) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Impresora no conectada.')));
        return;
      }

      final cashierName = ref.read(authProvider).user?.name ?? 'Operador';
      final reviewerName = ref.read(reviewerNameProvider);
      if (context.mounted) Navigator.pop(context); // Cerrar loader ANTES para evitar deadlock de UI con UsbManager
      
      final printResult = await ref.read(printerServiceProvider).printArqueoTicket(
        totalAmount: totalAmount,
        products: productList,
        cashierName: cashierName,
        reviewerName: reviewerName,
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
    final unclosedSales = await db.query(
      'transactions', 
      where: 'session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id != ? AND product_id != ?', 
      whereArgs: [sessionId, currentCashierId, 'CIERRE DE CAJA', 'APERTURA DE CAJA']
    );

    if (unclosedSales.isEmpty && !isArrastre) {
      if (context.mounted) {
        showEmptySalesModal(context, onClose: () {
          // Si venimos de la pantalla de conteo (isLogout = true), la cerramos para volver al Dashboard
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

    final payloadMap = {
      "c": cashierName,
      "b": branchId,
      "a": totalAmount,
      "q": unclosedSales.length - pmrCount,
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
      final allSales = await db.query(
        'transactions', 
        where: 'session_id = ? AND product_id != ? AND product_id != ? AND product_id != ?', 
        whereArgs: [sessionId, 'CIERRE DE CAJA', 'APERTURA DE CAJA', 'INGRESO_FISCALIZADOR']
      );
      
      int dayCount = 0;
      double dayTotalAmount = 0;
      Map<String, int> dayBreakdownQty = {};
      Map<String, double> dayBreakdownTotal = {};
      
      for (final sale in allSales) {
        if (sale['product_id'] == 'PMR') continue;
        final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
        final productId = sale['product_id']?.toString() ?? 'Desc.';
        dayCount++;
        dayTotalAmount += amount;
        dayBreakdownQty[productId] = (dayBreakdownQty[productId] ?? 0) + 1;
        dayBreakdownTotal[productId] = (dayBreakdownTotal[productId] ?? 0) + amount;
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

      daySummary = {
        'totalTransactions': dayCount,
        'totalAmount': dayTotalAmount,
        'breakdown': dayBreakdownLines
      };
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
      cashierId: currentCashierId.toString(),
      branchName: branchName,
      posLocationId: posLocationId,
      totalTransactions: unclosedSales.length - pmrCount,
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

    try {
      final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
      final int? currentSessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] as int : null;

      final random = math.Random();
      final plotIdBytes = List<int>.generate(16, (i) => random.nextInt(256));
      final plotId = md5.convert(plotIdBytes).toString();
      final macAddress = await DeviceUtils.getMacAddress();

      await db.insert('transactions', {
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
        'is_closed': 1, // EL CIERRE DE CAJA YA NACE CERRADO
        'plot_id': plotId,
        'mac_address': macAddress,
      });

      // Marcar las ventas cerradas por este cajero como cerradas
      await db.update(
        'transactions',
        {'is_closed': 1},
        where: 'session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id != ?',
        whereArgs: [currentSessionId, currentCashierId, 'CIERRE DE CAJA'],
      );
      // Ya no cerramos la sesión global, permitiendo a otros cajeros cerrar sus propias ventas después
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

    // Registrar cierre en el TXT local
    await PrintLogHelper.logClosure();

    if (!printSuccess) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo imprimir el cierre'),
            backgroundColor: Colors.orange));
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

    await ref.read(authProvider.notifier).logout();
    
    navigatorKey.currentState?.pop(); // close loader
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (route) => false);
  }
}
