import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/sales_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../auth/providers/auth_providers.dart';
import '../../auth/services/session_service.dart';
import '../models/tarifa_model.dart';
import 'dart:convert';

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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cierre de Caja'),
        content: const Text('¿Estás seguro de realizar el cierre? Se imprimirá un resumen y se limpiará el historial del dispositivo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _performClosing();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6642F8)),
            child: const Text('CONFIRMAR'),
          ),
        ],
      ),
    );
  }

  Future<void> _performClosing() async {
    final state = ref.read(salesHistoryProvider);
    if (state.sales.isEmpty) return;

    final user = ref.read(authProvider).user;
    final branchName = user?.branchName ?? 'Sucursal Valliu';
    final cashierName = user?.name ?? 'Operador';

    final branchId = user?.branchId ?? 0;

    double totalAmount = 0;
    Map<String, int> breakdownQty = {};
    Map<String, double> breakdownTotal = {};

    for (final sale in state.sales) {
      final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
      final productId = sale['product_id']?.toString() ?? 'Desc.';
      totalAmount += amount;
      breakdownQty[productId] = (breakdownQty[productId] ?? 0) + 1;
      breakdownTotal[productId] = (breakdownTotal[productId] ?? 0) + amount;
    }

    final productsState = ref.read(productsProvider);
    List<String> breakdownLines = [];
    breakdownQty.forEach((pId, qty) {
      final prod = productsState.products.firstWhere(
        (p) => p.id == pId, 
        orElse: () => Product(id: pId, productName: 'Tarifa $pId', value: 0)
      );
      final t = breakdownTotal[pId] ?? 0;
      final qtyStr = '${qty}x'.padRight(4);
      final nameStr = prod.productName.length > 15 ? prod.productName.substring(0, 15) : prod.productName.padRight(15);
      final valStr = '\$${t.toStringAsFixed(0)}'.padLeft(8);
      breakdownLines.add('$qtyStr $nameStr $valStr');
    });

    final nowUtc = DateTime.now().toUtc();
    final now = nowUtc.subtract(const Duration(hours: 5));
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final dateStr = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

    final jsonStr = jsonEncode({
      "c": cashierName,
      "b": branchId,
      "a": totalAmount,
      "q": state.sales.length,
      "d": dateStr,
      "t": timeStr,
      "v": "v1"
    });

    final qrData = base64Encode(utf8.encode(jsonStr));

    // Mostrar loader
    showDialog(
      context: context, 
      barrierDismissible: false, 
      builder: (ctx) => const Center(child: CircularProgressIndicator())
    );

    // Imprimir
    final printer = ref.read(printerServiceProvider);
    final printSuccess = await printer.printClosingTicket(
      cashierName: cashierName,
      branchName: branchName,
      totalTransactions: state.sales.length,
      totalAmount: totalAmount,
      startTime: 'Inicio de turno',
      endTime: timeStr,
      qrData: qrData,
      breakdown: breakdownLines,
    );

    if (mounted) Navigator.pop(context); // Quitar loader

    if (printSuccess) {
      // Si imprimió bien, cerramos sesión local, vaciamos vista y salimos
      await ref.read(sessionServiceProvider).closeSession(branchId);
      await ref.read(salesHistoryProvider.notifier).clearHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cierre de caja exitoso'), backgroundColor: Colors.green)
        );
        await ref.read(authProvider.notifier).logout();
        Navigator.of(context).pushReplacementNamed('/login');
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al imprimir el cierre. Intente de nuevo.'), backgroundColor: Colors.red)
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyState = ref.watch(salesHistoryProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      floatingActionButton: (historyState.status == SalesHistoryStatus.loaded && historyState.sales.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: () => _showClosingConfirmation(),
              label: const Text('CIERRE DE CAJA'),
              icon: const Icon(Icons.summarize_rounded),
              backgroundColor: const Color(0xFF6642F8),
            )
          : null,
      body: Column(
        children: [
          _buildSearchBar(),
          if (historyState.status == SalesHistoryStatus.loaded) _buildSummaryCard(historyState),
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
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF6642F8)),
                suffixIcon: _isSearching 
                  ? IconButton(
                      icon: const Icon(Icons.close), 
                      onPressed: () => _clearSearch()
                    ) 
                  : null,
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(SalesHistoryState state) {
    double totalAmount = 0;
    for (final sale in state.sales) {
      totalAmount += (sale['amount'] as num?)?.toDouble() ?? 0;
    }

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(20), 
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))]
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _summaryItem(icon: Icons.receipt_long_rounded, label: 'Total Ventas', value: '${state.total}'),
          Container(width: 1, height: 30, color: Colors.grey.shade100),
          _summaryItem(icon: Icons.payments_rounded, label: 'Recaudado', value: '\$ ${_formatCurrency(totalAmount)}'),
        ],
      ),
    );
  }

  Widget _summaryItem({required IconData icon, required String label, required String value}) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF6642F8), size: 24),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(color: Color(0xFF3F3D56), fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }

  Widget _buildTransactionList(SalesHistoryState state) {
    if (state.status == SalesHistoryStatus.loading) return const Center(child: CircularProgressIndicator());
    
    if (state.status == SalesHistoryStatus.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Historial de ventas locales',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.read(salesHistoryProvider.notifier).fetchHistory(),
                child: const Text('REINTENTAR'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.sales.isEmpty) return const Center(child: Text('No hay transacciones hoy', style: TextStyle(color: Colors.grey)));

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: state.sales.length,
      itemBuilder: (context, index) => _buildTransactionTile(state.sales[index]),
    );
  }

  Widget _buildTransactionTile(Map<String, dynamic> sale) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.01), blurRadius: 5, offset: const Offset(0, 2))]),
      child: Row(
        children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: const Color(0xFFF5F7FA), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.qr_code_rounded, color: Color(0xFF6642F8))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Transacción #${sale['id'] ?? '—'}', style: const TextStyle(color: Color(0xFF3F3D56), fontWeight: FontWeight.bold, fontSize: 15)),
                Text(sale['created_at']?.toString() ?? '', style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),
          Text('\$ ${_formatCurrency((sale['amount'] as num?)?.toDouble() ?? 0)}', style: const TextStyle(color: Color(0xFF6642F8), fontWeight: FontWeight.w900, fontSize: 18)),
        ],
      ),
    );
  }

  String _formatCurrency(double value) {
    // Para COP (Pesos Colombianos) sobran los decimales en la mayoría de casos
    final intPart = value.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return intPart;
  }
}
