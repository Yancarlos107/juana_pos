import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/sales_providers.dart';
import '../../../core/database/database_helper.dart';
import '../../printer/services/printer_service.dart';
import '../../auth/providers/auth_providers.dart';
import '../../auth/services/session_service.dart';
import '../models/tarifa_model.dart';
import '../services/closure_service.dart';
import '../../monitoring/services/system_status_service.dart';
import 'dart:convert';
import '../helpers/closing_helper.dart';

class RecaudoScreen extends ConsumerStatefulWidget {
  const RecaudoScreen({super.key});

  @override
  ConsumerState<RecaudoScreen> createState() => _RecaudoScreenState();
}

class _RecaudoScreenState extends ConsumerState<RecaudoScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesHistoryProvider.notifier).fetchHistory();
    });
  }

  void _showClosingConfirmation() {
    ClosingHelper.showClosingConfirmation(context, ref, isLogout: true);
  }

  @override
  Widget build(BuildContext context) {
    final historyState = ref.watch(salesHistoryProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      floatingActionButton: (historyState.status == SalesHistoryStatus.loaded &&
              historyState.sales.any((s) => s['is_closed'] != true))
          ? FloatingActionButton.extended(
              onPressed: () => _showClosingConfirmation(),
              label: const Text('CIERRE DE CAJA'),
              icon: const Icon(Icons.summarize_rounded),
              backgroundColor: const Color(0xFF6642F8),
              foregroundColor: Colors.white,
            )
          : null,
      body: Column(
        children: [
          if (historyState.status == SalesHistoryStatus.loaded)
            _buildSummaryCard(historyState),
          Expanded(child: _buildTransactionList(historyState)),
        ],
      ),
    );
  }



  Widget _buildSummaryCard(SalesHistoryState state) {
    double totalAmount = 0;
    int unclosedCount = 0;
    for (final sale in state.sales) {
      if (sale['is_closed'] != true) {
        totalAmount += (sale['amount'] as num?)?.toDouble() ?? 0;
        unclosedCount++;
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ]),
      child: Row(
        children: [
          Expanded(
            child: _summaryItem(
                icon: Icons.receipt_long_rounded,
                label: 'Ventas:',
                value: '$unclosedCount'),
          ),
          Container(width: 1, height: 24, color: const Color(0xFFE0E0E0)),
          const SizedBox(width: 16),
          Expanded(
            child: _summaryItem(
                icon: Icons.payments_rounded,
                label: 'Recaudo:',
                value: '\$ ${_formatCurrency(totalAmount)}'),
          ),
        ],
      ),
    );
  }

  Widget _summaryItem(
      {required IconData icon, required String label, required String value}) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF6642F8), size: 36),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 18, fontWeight: FontWeight.w500)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Color(0xFF3F3D56),
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _buildTransactionList(SalesHistoryState state) {
    if (state.status == SalesHistoryStatus.loading)
      return const Center(child: CircularProgressIndicator());

    if (state.status == SalesHistoryStatus.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Historial de ventas locales',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () =>
                    ref.read(salesHistoryProvider.notifier).fetchHistory(),
                child: const Text('REINTENTAR'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.sales.isEmpty)
      return const Center(
          child: Text('No hay transacciones hoy',
              style: TextStyle(color: Colors.grey)));

    return ListView.builder(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 100),
      itemCount: state.sales.length,
      itemBuilder: (context, index) =>
          _buildTransactionTile(state.sales[index]),
    );
  }

  Widget _buildTransactionTile(Map<String, dynamic> sale) {
    final printStatus = sale['print_status'] as int? ?? 0;
    
    // Convertir 'created_at' de ISO 8601 a un formato corto (ej: 2026-05-28 14:30)
    final String dateStr = sale['created_at']?.toString() ?? '';
    String timeOnly = dateStr;
    try {
      if (dateStr.isNotEmpty) {
        final parsed = DateTime.parse(dateStr);
        timeOnly = "${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}";
      }
    } catch (_) {}

    final String product = sale['product_name'] ?? sale['product_id'] ?? 'TARIFA';
    final double amount = (sale['amount'] as num?)?.toDouble() ?? 0;
    final bool isClosed = sale['is_closed'] == true;
    final String statusText = isClosed ? ' (CERRADO)' : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.01),
                blurRadius: 5,
                offset: const Offset(0, 2))
          ]),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              '$timeOnly - $product - \$ ${_formatCurrency(amount)}$statusText',
              style: TextStyle(
                  color: isClosed ? Colors.red : const Color(0xFF3F3D56),
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
            ),
          ),
          if ((!isClosed && printStatus < 2) || product == 'CIERRE DE CAJA')
            InkWell(
              onTap: () => _handlePrint(sale),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: printStatus == 0
                      ? Colors.green.withOpacity(0.1)
                      : Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        printStatus == 0
                            ? Icons.print_rounded
                            : Icons.replay_rounded,
                        size: 16,
                        color: printStatus == 0
                            ? Colors.green
                            : Colors.orange),
                    const SizedBox(width: 6),
                    Text(printStatus == 0 ? 'IMPRIMIR' : 'REIMPRIMIR',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: printStatus == 0
                                ? Colors.green
                                : Colors.orange)),
                  ],
                ),
              ),
            )
          else
            const Text('REIMPRESO',
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _handlePrint(Map<String, dynamic> sale) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    final isPrinterConnected =
        await ref.read(systemStatusProvider.notifier).checkPrinterNow();

    if (mounted) Navigator.pop(context); // Cerrar loading

    if (!isPrinterConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impresora no detectada.'),
          backgroundColor: Colors.redAccent));
      return;
    }

    final printStatus = sale['print_status'] as int? ?? 0;
    final transactionId = sale['id']?.toString() ?? '';
    final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
    final qrData = sale['qr_data']?.toString() ?? '';
    final pId = sale['product_id']?.toString() ?? '';

    final productsState = ref.read(productsProvider);
    final prod = productsState.products.firstWhere((p) => p.id == pId,
        orElse: () =>
            Product(id: pId, productName: 'Tarifa $pId', value: amount));

    final db = await DatabaseHelper.instance.database;
    final txCashierId = sale['cashier_id'] as int?;
    final userQuery = txCashierId != null 
        ? await db.query('users', where: 'id = ?', whereArgs: [txCashierId], limit: 1)
        : null;
    
    final fallbackAuth = ref.read(authProvider).user?.name ?? 'Operador';
    final cashierName = userQuery != null && userQuery.isNotEmpty 
        ? (userQuery.first['name']?.toString() ?? fallbackAuth) 
        : fallbackAuth;
    final storage = ref.read(salesStorageProvider);
    final posName = await storage.getPosLocationName();
    final branchName = posName ?? ref.read(authProvider).user?.branchName ?? 'Sucursal Juana';

    final isReprint = printStatus == 1;

    final printer = ref.read(printerServiceProvider);
    bool? printResult;

    if (pId == 'CIERRE DE CAJA') {
      try {
        final jsonStr = utf8.decode(base64Decode(qrData));
        final data = jsonDecode(jsonStr);
        printResult = await printer.printClosingTicket(
          cashierName: data['c']?.toString() ?? cashierName,
          branchName: branchName,
          totalTransactions: data['q'] ?? 0,
          totalAmount: (data['a'] as num?)?.toDouble() ?? amount,
          startTime: 'Turno',
          endTime: data['d']?.toString() ?? '',
          qrData: qrData,
          pmrCount: data['pmr_q'] ?? 0,
          reprintsCount: printStatus,
        );
      } catch (e) {
        printResult = false;
      }
    } else {
      final localId = sale['local_id'] as int? ?? 0;
      final deviceHash = await ref.read(salesStorageProvider).getDeviceHash();
      final serialNumber = '$deviceHash-${localId.toString().padLeft(7, '0')}';

      printResult = await printer.printTicket(
        transactionId: serialNumber,
        amount: amount,
        qrData: qrData,
        cashierName: cashierName,
        branchName: branchName,
        productName: prod.productName,
        isReprint: isReprint,
      );
    }

    // null = permiso USB pendiente (Epson): el usuario debe aceptar el diálogo y reintentar
    if (printResult == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Acepta el permiso USB e intenta de nuevo'),
            backgroundColor: Colors.orange));
      }
      return;
    }

    final success = printResult;
    if (success) {
      if (pId == 'CIERRE DE CAJA') {
        // Incrementamos el print_status pero nunca lo bloqueamos
        await ref.read(salesHistoryProvider.notifier).markAsPrinted(transactionId, printStatus + 1);
      } else {
        final newStatus = printStatus == 0 ? 1 : 2;
        await ref.read(salesHistoryProvider.notifier).markAsPrinted(transactionId, newStatus);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Error al imprimir ticket'),
            backgroundColor: Colors.redAccent));
      }
    }
  }

  String _formatCurrency(double value) {
    final hasDecimals = value % 1 != 0;
    if (hasDecimals) {
      final parts = value.toStringAsFixed(2).split('.');
      final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
      return '$intPart.${parts[1]}';
    } else {
      return value.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
  }
}
