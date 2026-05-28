import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/sales_providers.dart';
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
  final _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesHistoryProvider.notifier).fetchHistory();
    });
  }

  void _performSearch() {
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      setState(() => _isSearching = true);
      ref.read(salesHistoryProvider.notifier).search(query);
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _isSearching = false);
    ref.read(salesHistoryProvider.notifier).fetchHistory();
  }

  void _showClosingConfirmation() {
    ClosingHelper.showClosingConfirmation(context, ref, isLogout: false);
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
          _buildSearchBar(),
          if (historyState.status == SalesHistoryStatus.loaded)
            _buildSummaryCard(historyState),
          Expanded(child: _buildTransactionList(historyState)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Buscar transacción...',
                prefixIcon:
                    const Icon(Icons.search_rounded, color: Color(0xFF6642F8)),
                suffixIcon: _isSearching
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => _clearSearch())
                    : null,
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none),
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _performSearch(),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: () => _performSearch(),
            icon: const Icon(Icons.filter_list_rounded, color: Colors.white),
            style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF6642F8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16))),
          ),
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
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ]),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _summaryItem(
              icon: Icons.receipt_long_rounded,
              label: 'Total Ventas',
              value: '$unclosedCount'),
          Container(width: 1, height: 30, color: Colors.grey.shade100),
          _summaryItem(
              icon: Icons.payments_rounded,
              label: 'Recaudado',
              value: '\$ ${_formatCurrency(totalAmount)}'),
        ],
      ),
    );
  }

  Widget _summaryItem(
      {required IconData icon, required String label, required String value}) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF6642F8), size: 24),
        const SizedBox(height: 6),
        Text(value,
            style: const TextStyle(
                color: Color(0xFF3F3D56),
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
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
    final isClosed = sale['is_closed'] == true;
    final printStatus = sale['print_status'] as int? ?? 0;

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
        children: [
          Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F7FA),
                  borderRadius: BorderRadius.circular(12)),
              child:
                  const Icon(Icons.qr_code_rounded, color: Color(0xFF6642F8))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Transacción #${sale['id'] ?? '—'}',
                    style: const TextStyle(
                        color: Color(0xFF3F3D56),
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
                Row(
                  children: [
                    Text(sale['created_at']?.toString() ?? '',
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                    if (isClosed)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text('[CERRADA]',
                            style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                  '\$ ${_formatCurrency((sale['amount'] as num?)?.toDouble() ?? 0)}',
                  style: TextStyle(
                      color: isClosed ? Colors.grey : const Color(0xFF6642F8),
                      fontWeight: FontWeight.w900,
                      fontSize: 18)),
              if (printStatus < 2) ...[
                const SizedBox(height: 4),
                InkWell(
                  onTap: () => _handlePrint(sale),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                            size: 14,
                            color: printStatus == 0
                                ? Colors.green
                                : Colors.orange),
                        const SizedBox(width: 4),
                        Text(printStatus == 0 ? 'Imprimir' : 'Reimprimir',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: printStatus == 0
                                    ? Colors.green
                                    : Colors.orange)),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 4),
                const Text('Reimpreso',
                    style: TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontStyle: FontStyle.italic)),
              ]
            ],
          ),
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

    final cashierName = ref.read(authProvider).user?.name ?? 'Operador';
    final branchName =
        ref.read(authProvider).user?.branchName ?? 'Sucursal Juana';

    final isReprint = printStatus == 1;

    final printer = ref.read(printerServiceProvider);
    final success = await printer.printTicket(
      transactionId: transactionId,
      amount: amount,
      qrData: qrData,
      cashierName: cashierName,
      branchName: branchName,
      productName: prod.productName,
      isReprint: isReprint,
    );

    if (success) {
      final newStatus = printStatus == 0 ? 1 : 2;
      await ref
          .read(salesHistoryProvider.notifier)
          .markAsPrinted(transactionId, newStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(isReprint ? 'Reimpresión exitosa' : 'Impresión exitosa'),
            backgroundColor: Colors.green));
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
    // Para COP (Pesos Colombianos) sobran los decimales en la mayoría de casos
    final intPart = value
        .toStringAsFixed(0)
        .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return intPart;
  }
}
