import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dio/dio.dart';
import '../../../core/network/dio_client.dart';
import '../../auth/providers/auth_providers.dart';
import '../models/tarifa_model.dart';
import '../providers/sales_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../monitoring/services/system_status_service.dart';
import 'recaudo_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _currentIndex = 0;
  Product? _selectedProduct;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Cargamos el saldo local inmediatamente para evitar parpadeos
      ref.read(balanceProvider.notifier).loadLocalBalance();
      _loadBalance();
      ref.read(productsProvider.notifier).fetchProducts();
    });
  }

  void _loadBalance() {
    final branchId = ref.read(authProvider).user?.branchId;
    if (branchId != null) {
      ref.read(balanceProvider.notifier).fetchBalance(branchId);
    }
  }

  void _processQrSale() async {
    if (_selectedProduct == null) {
      _showSnackBar('Seleccione una tarifa para continuar.', Icons.warning_amber_rounded, Colors.amber.shade800);
      return;
    }

    final success = await ref.read(qrPurchaseProvider.notifier).purchase(product: _selectedProduct!);

    if (success && mounted) {
      if (_selectedProduct!.pmr) {
        try {
          final dio = ref.read(dioProvider);
          // Mock temporal: Endpoint físico de apertura PMR (Raspberry/Relay local)
          await dio.post('http://192.168.1.100/open-pmr', options: Options(sendTimeout: const Duration(seconds: 1), receiveTimeout: const Duration(seconds: 1)));
        } catch (_) {
          print('DEBUG: Endpoint PMR físico inalcanzable. Se omitió la apertura física.');
        }
      }

      final result = ref.read(qrPurchaseProvider).result;
      
      // Actualizamos la UI inmediatamente restando el valor localmente
      final currentBalance = ref.read(balanceProvider).balance;
      ref.read(balanceProvider.notifier).updateBalanceState(currentBalance - _selectedProduct!.value);
      
      _loadBalance(); // Sincronizamos con API en segundo plano
      // Refrescamos el historial de recaudo para que aparezca la nueva venta
      ref.read(salesHistoryProvider.notifier).fetchHistory();
      
      if (result != null) _showQrResultDialog(result);
    } else if (!success && mounted) {
      final error = ref.read(qrPurchaseProvider).errorMessage ?? '';
      if (error.contains('Saldo insuficiente')) {
        _showInsufficientBalanceDialog(error);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.isEmpty ? 'Error al generar QR' : error), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showInsufficientBalanceDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Saldo Insuficiente', style: TextStyle(color: Color(0xFF3F3D56), fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 16)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ENTENDIDO', style: TextStyle(color: Color(0xFF6642F8), fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  void _showQrResultDialog(QrPurchaseResult result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Color(0xFF6642F8), size: 28),
            SizedBox(width: 12),
            Text('¡Venta Exitosa!', style: TextStyle(color: Color(0xFF3F3D56), fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Escanee el código para abordar', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade100),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: QrImageView(
                data: result.qrCode,
                version: QrVersions.auto,
                size: 200.0,
                gapless: false,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF3F3D56)),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF3F3D56)),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFFF5F7FA), borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  _infoRow('Transacción', '#${result.transactionId}'),
                  const Divider(height: 16, color: Colors.white),
                  _infoRow('Tarifa', _selectedProduct?.productName ?? '—'),
                  const Divider(height: 16, color: Colors.white),
                  _infoRow('Valor', '\$ ${_selectedProduct?.value.toStringAsFixed(0) ?? '—'}'),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              final pmrLabel = (_selectedProduct?.pmr == true) ? ' [PMR]' : '';
              ref.read(printerServiceProvider).printTicket(
                transactionId: result.transactionId,
                amount: _selectedProduct?.value ?? 0,
                qrData: result.qrCode,
                cashierName: ref.read(authProvider).user?.name ?? 'Operador',
                productName: '${_selectedProduct?.productName ?? ''}$pmrLabel',
              );
              Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.print_rounded),
            label: const Text('IMPRIMIR TICKET'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF6642F8),
              backgroundColor: const Color(0xFF6642F8).withOpacity(0.1),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('CERRAR', style: TextStyle(color: Colors.grey))),
        ],
        actionsAlignment: MainAxisAlignment.center,
        actionsPadding: const EdgeInsets.only(bottom: 20, left: 20, right: 20),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
        Text(value, style: const TextStyle(color: Color(0xFF3F3D56), fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    );
  }

  void _showLogoutDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Row(
          children: [
            Icon(Icons.exit_to_app_rounded, color: Colors.redAccent, size: 28),
            SizedBox(width: 12),
            Text('Cerrar Sesión', style: TextStyle(color: Color(0xFF3F3D56))),
          ],
        ),
        content: const Text(
          '¿Deseas realizar el Cierre de Caja antes de salir?\n\n'
          'Si sales sin cerrar la caja, la sesión quedará abierta localmente.',
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // TODO: Redirigir a flujo de cierre de caja (Módulo 5)
              // Por ahora, forzamos logout
              await ref.read(authProvider.notifier).logout();
              if (mounted) Navigator.of(context).pushReplacementNamed('/login');
            },
            child: const Text('IR A CERRAR CAJA', style: TextStyle(color: Color(0xFF6642F8), fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(authProvider.notifier).logout();
              if (mounted) Navigator.of(context).pushReplacementNamed('/login');
            },
            child: const Text('SALIR SIN CERRAR', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, IconData icon, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [Icon(icon, color: Colors.white), const SizedBox(width: 12), Expanded(child: Text(message))]),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final balanceState = ref.watch(balanceProvider);
    final productsState = ref.watch(productsProvider);
    final qrState = ref.watch(qrPurchaseProvider);
    final systemStatus = ref.watch(systemStatusProvider);

    ref.listen<QrPurchaseState>(qrPurchaseProvider, (prev, next) {
      if (next.status == QrPurchaseStatus.error && next.errorMessage != null) {
        _showSnackBar(next.errorMessage!, Icons.error_outline, Colors.redAccent);
      }
    });

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: Row(
          children: [
            Image.asset(
              'assets/valliu-logo.png',
              height: 32,
              errorBuilder: (ctx, err, stack) => const Icon(Icons.point_of_sale_rounded, color: Color(0xFF6642F8)),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (balanceState.status == BalanceStatus.loading)
                  const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else if (balanceState.status == BalanceStatus.error)
                  const Text('Error', style: TextStyle(fontSize: 14, color: Colors.redAccent))
                else
                  Text(
                    '\$ ${_formatCurrency(balanceState.balance, showDecimals: false)}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF3F3D56)),
                  ),
                Text(authState.user?.name ?? 'Operador', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ],
        ),
        actions: [
          Icon(Icons.accessible_rounded, color: systemStatus.isPmrConnected ? Colors.green : Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Icon(Icons.print_rounded, color: systemStatus.isPrinterConnected ? Colors.green : Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Icon(Icons.wifi_rounded, color: systemStatus.isInternetConnected ? Colors.green : Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          if (systemStatus.pendingTransactions > 0)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(12)),
                child: Text('${systemStatus.pendingTransactions}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh_rounded, color: Color(0xFF3F3D56)), onPressed: () {
            _loadBalance();
            ref.read(productsProvider.notifier).fetchProducts();
          }),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
            onPressed: () => _showLogoutDialog(context, ref),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: [
        _buildSalesView(balanceState, productsState, qrState),
        _buildRecaudoSection(),
      ]),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -2))]),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: Colors.white,
          elevation: 0,
          selectedItemColor: const Color(0xFF6642F8),
          unselectedItemColor: Colors.grey,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
          items: const [BottomNavigationBarItem(icon: Icon(Icons.qr_code_2_rounded), label: 'Ventas QR'), BottomNavigationBarItem(icon: Icon(Icons.receipt_long_rounded), label: 'Recaudo')],
        ),
      ),
    );
  }

  Widget _buildSalesView(BalanceState balanceState, ProductsState productsState, QrPurchaseState qrState) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildQrSaleCard(productsState, qrState),
        ],
      ),
    );
  }

  Widget _buildBalanceCard(BalanceState balanceState) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF6642F8), Color(0xFF4A2CB3)]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: const Color(0xFF6642F8).withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Saldo del Punto de Venta', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          if (balanceState.status == BalanceStatus.loading)
            const CircularProgressIndicator(color: Colors.white70)
          else if (balanceState.status == BalanceStatus.error)
            Text(balanceState.errorMessage ?? 'Error', style: const TextStyle(color: Colors.white70))
          else
            Text('\$ ${_formatCurrency(balanceState.balance)}', style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
          const SizedBox(height: 8),
          Text('Sucursal #${ref.read(authProvider).user?.branchId ?? "—"}', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildQrSaleCard(ProductsState productsState, QrPurchaseState qrState) {
    final isLoading = qrState.status == QrPurchaseStatus.loading;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF6642F8).withOpacity(0.1), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF6642F8), size: 24)),
            const SizedBox(width: 14),
            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Venta Tickete', style: TextStyle(color: Color(0xFF3F3D56), fontSize: 18, fontWeight: FontWeight.bold)), Text('Seleccione una tarifa', style: TextStyle(color: Colors.grey, fontSize: 12))]),
          ]),
          const SizedBox(height: 32),
          if (productsState.status == ProductsStatus.loading)
            const Center(child: CircularProgressIndicator(color: Color(0xFF6642F8)))
          else if (productsState.status == ProductsStatus.error)
            Text(productsState.errorMessage ?? 'Error', style: const TextStyle(color: Colors.redAccent))
          else ...[
            const Text('Tipo de Tarifa', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF3F3D56))),
            const SizedBox(height: 8),
            DropdownButtonFormField<Product>(
              value: _selectedProduct,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: 'Seleccione una tarifa...',
              ),
              items: productsState.products.map((p) => DropdownMenuItem(
                value: p, 
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(p.displayLabel),
                    if (p.pmr) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.accessible_rounded, color: Colors.blue, size: 16),
                    ],
                  ],
                ),
              )).toList(),
              onChanged: (v) => setState(() => _selectedProduct = v),
            ),
          ],
          const SizedBox(height: 24),
          const TextField(
            enabled: false,
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.people_alt_rounded, size: 20),
              hintText: '1',
              floatingLabelBehavior: FloatingLabelBehavior.never,
            ),
            controller: null, // Si usara controller, pondría '1'
          ),
          // Usamos un valor fijo visual
          const Center(child: Text('Cantidad: 1 persona', style: TextStyle(fontSize: 12, color: Colors.grey))),
          const SizedBox(height: 40),
          ElevatedButton.icon(
            onPressed: isLoading ? null : _processQrSale,
            icon: isLoading 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
              : (_selectedProduct?.pmr == true ? const Icon(Icons.accessible_forward_rounded) : const Icon(Icons.qr_code_2_rounded)),
            label: Text(isLoading 
              ? 'PROCESANDO...' 
              : (_selectedProduct?.pmr == true ? 'GENERAR VENTA Y ABRIR PMR' : 'GENERAR VENTA QR')),
          ),
        ],
      ),
    );
  }

  Widget _buildRecaudoSection() {
    // Aquí podrías envolver la pantalla de recaudo o llamarla directamente
    // Para simplificar, asumimos que RecaudoScreen es un widget separado que importamos
    return const RecaudoScreen(); 
  }

  String _formatCurrency(double value, {bool showDecimals = true}) {
    final parts = value.toStringAsFixed(showDecimals ? 2 : 0).split('.');
    final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return showDecimals && parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
  }
}
