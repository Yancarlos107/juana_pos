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
import '../../../core/database/database_helper.dart';
import '../../sync/services/init_service.dart';
import '../services/closure_service.dart';
import '../../auth/services/session_service.dart';
import 'dart:async';
import 'recaudo_screen.dart';
import '../helpers/closing_helper.dart';

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

  void _processQrSaleMultiple(int quantity) async {
    if (_selectedProduct == null) {
      _showSnackBar('Seleccione una tarifa para continuar.',
          Icons.warning_amber_rounded, Colors.amber.shade800);
      return;
    }

    int successfulPrints = 0;
    QrPurchaseResult? lastResult;

    for (int i = 0; i < quantity; i++) {
      final success = await ref
          .read(qrPurchaseProvider.notifier)
          .purchase(product: _selectedProduct!);

      if (success && mounted) {
        final result = ref.read(qrPurchaseProvider).result;

        final currentBalance = ref.read(balanceProvider).balance;
        ref
            .read(balanceProvider.notifier)
            .updateBalanceState(currentBalance - _selectedProduct!.value);

        if (result != null) {
          lastResult = result;
          // Si es venta múltiple imprimimos en lote automáticamente
          // Si es una sola venta, NO imprimimos automático, dejamos que lo haga desde el modal (como antes)
          if (quantity > 1) {
            final pmrLabel = (_selectedProduct?.pmr == true) ? ' [PMR]' : '';
            final storage = ref.read(localStorageProvider);
            final posName = await storage.getPosLocationName();
            final branchName = posName ?? ref.read(authProvider).user?.branchName;
            
            final printSuccess = await ref
                .read(printerServiceProvider)
                .printTicket(
                  transactionId: result.transactionId,
                  amount: _selectedProduct!.value,
                  qrData: result.qrCode,
                  cashierName: ref.read(authProvider).user?.name ?? 'Operador',
                  branchName: branchName,
                  productName: '${_selectedProduct!.productName}$pmrLabel',
                );
            if (printSuccess) {
              await ref
                  .read(salesHistoryProvider.notifier)
                  .markAsPrinted(result.transactionId, 1);
            }
            await Future.delayed(
                const Duration(milliseconds: 500)); // Pausa entre impresiones
          }
          successfulPrints++;
        }
      } else if (!success && mounted) {
        final error = ref.read(qrPurchaseProvider).errorMessage ?? '';
        if (error.contains('Saldo insuficiente')) {
          _showInsufficientBalanceDialog(error);
        } else {
          _showSnackBar(error.isEmpty ? 'Error al generar QR' : error,
              Icons.error, Colors.red);
        }
        _loadBalance();
        ref.read(salesHistoryProvider.notifier).fetchHistory();
        return; // Detener loop
      }
    }

    _loadBalance();
    ref.read(salesHistoryProvider.notifier).fetchHistory();

    if (mounted && successfulPrints > 0) {
      if (quantity == 1 && lastResult != null) {
        _showQrResultDialog(lastResult);
      } else {
        _showSnackBar('Se generaron $successfulPrints ticket(s) exitosamente.',
            Icons.check_circle, Colors.green);
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
            Text('Saldo Insuficiente',
                style: TextStyle(
                    color: Color(0xFF3F3D56), fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 16)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ENTENDIDO',
                  style: TextStyle(
                      color: Color(0xFF6642F8),
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
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
            Icon(Icons.check_circle_rounded,
                color: Color(0xFF6642F8), size: 28),
            SizedBox(width: 12),
            Text('¡Venta Exitosa!',
                style: TextStyle(
                    color: Color(0xFF3F3D56), fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Escanee el código para abordar',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade100),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4))
                ],
              ),
              child: QrImageView(
                data: result.qrCode,
                version: QrVersions.auto,
                size: 200.0,
                gapless: false,
                eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square, color: Color(0xFF3F3D56)),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF3F3D56)),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F7FA),
                  borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  _infoRow('Transacción', '#${result.transactionId}'),
                  const Divider(height: 16, color: Colors.white),
                  _infoRow('Tarifa', _selectedProduct?.productName ?? '—'),
                  const Divider(height: 16, color: Colors.white),
                  _infoRow('Valor',
                      '\$ ${_selectedProduct?.value.toStringAsFixed(0) ?? '—'}'),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (ref.read(systemStatusProvider).isPrinterConnected)
            TextButton.icon(
              onPressed: () async {
                final pmrLabel =
                    (_selectedProduct?.pmr == true) ? ' [PMR]' : '';
                final storage = ref.read(localStorageProvider);
                final posName = await storage.getPosLocationName();
                final branchName = posName ?? ref.read(authProvider).user?.branchName;

                final printSuccess =
                    await ref.read(printerServiceProvider).printTicket(
                          transactionId: result.transactionId,
                          amount: _selectedProduct?.value ?? 0,
                          qrData: result.qrCode,
                          cashierName:
                              ref.read(authProvider).user?.name ?? 'Operador',
                          branchName: branchName,
                          productName:
                              '${_selectedProduct?.productName ?? ''}$pmrLabel',
                        );
                if (printSuccess) {
                  await ref
                      .read(salesHistoryProvider.notifier)
                      .markAsPrinted(result.transactionId, 1);
                }
                if (mounted) Navigator.of(ctx).pop();
              },
              icon: const Icon(Icons.print_rounded),
              label: const Text('IMPRIMIR TICKET'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF6642F8),
                backgroundColor: const Color(0xFF6642F8).withOpacity(0.1),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child:
                  const Text('CERRAR', style: TextStyle(color: Colors.grey))),
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
        Text(label,
            style: const TextStyle(
                color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
        Text(value,
            style: const TextStyle(
                color: Color(0xFF3F3D56),
                fontWeight: FontWeight.bold,
                fontSize: 13)),
      ],
    );
  }

  void _showLogoutDialog(BuildContext context, WidgetRef ref) {
    ClosingHelper.showClosingConfirmation(context, ref, isLogout: true);
  }

  void _showSnackBar(String message, IconData icon, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(child: Text(message))
        ]),
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
        _showSnackBar(
            next.errorMessage!, Icons.error_outline, Colors.redAccent);
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
              'assets/Juana-logo.png',
              height: 32,
              errorBuilder: (ctx, err, stack) => const Icon(
                  Icons.point_of_sale_rounded,
                  color: Color(0xFF6642F8)),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (balanceState.status == BalanceStatus.loading)
                  const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else if (balanceState.status == BalanceStatus.error)
                  const Text('Error',
                      style: TextStyle(fontSize: 14, color: Colors.redAccent))
                else
                  Text(
                    '\$ ${_formatCurrency(balanceState.balance, showDecimals: false)}',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF3F3D56)),
                  ),
                Row(
                  children: [
                    Text(authState.user?.name ?? 'Operador',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(width: 8),
                    const _ClockWidget(),
                  ],
                ),
              ],
            ),
          ],
        ),
        actions: [
          Icon(Icons.accessible_rounded,
              color:
                  systemStatus.isPmrConnected ? Colors.green : Colors.redAccent,
              size: 20),
          const SizedBox(width: 8),
          Icon(Icons.camera_alt_rounded,
              color: systemStatus.isCameraConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 20),
          const SizedBox(width: 8),
          Icon(Icons.print_rounded,
              color: systemStatus.isPrinterConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 20),
          const SizedBox(width: 8),
          Icon(Icons.wifi_rounded,
              color: systemStatus.isInternetConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 20),
          const SizedBox(width: 8),
          if (systemStatus.pendingTransactions > 0)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(12)),
                child: Text('${systemStatus.pendingTransactions}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF3F3D56)),
              onPressed: () {
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
        decoration: BoxDecoration(color: Colors.white, boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -2))
        ]),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: Colors.white,
          elevation: 0,
          selectedItemColor: const Color(0xFF6642F8),
          unselectedItemColor: Colors.grey,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_2_rounded), label: 'Ventas QR'),
            BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_rounded), label: 'Recaudo')
          ],
        ),
      ),
    );
  }

  Widget _buildSalesView(BalanceState balanceState, ProductsState productsState,
      QrPurchaseState qrState) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sidebar (20%)
        Container(
          width: MediaQuery.of(context).size.width * 0.20,
          padding: const EdgeInsets.only(top: 20, bottom: 20, left: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSidebarButton(
                icon: Icons.accessible_rounded,
                label: 'PMR',
                color: Colors.blue,
                onPressed: _confirmPmr,
              ),
              const SizedBox(height: 16),
              _buildSidebarButton(
                icon: Icons.warning_rounded,
                label: 'Pánico',
                color: Colors.redAccent,
                onPressed: () async {
                  // Mostrar loading
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF6642F8))),
                  );

                  try {
                    final initService = ref.read(initServiceProvider);
                    await initService.sendNovelty(1, 'Pánico');
                    if (mounted) Navigator.pop(context); // Cerrar loading
                    _showNovedadSuccess('Pánico');
                  } catch (e) {
                    if (mounted) Navigator.pop(context); // Cerrar loading
                    _showSnackBar('Error al reportar pánico: ${e.toString()}',
                        Icons.error_outline, Colors.redAccent);
                  }
                },
              ),
              const SizedBox(height: 16),
              _buildSidebarButton(
                icon: Icons.report_problem_rounded,
                label: 'Novedades',
                color: Colors.orange,
                onPressed: _showNovedadesModal,
              ),
            ],
          ),
        ),
        // Contenido Principal (80%)
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildQrSaleCard(productsState, qrState),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSidebarButton(
      {required IconData icon,
      required String label,
      required Color color,
      required VoidCallback onPressed}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 4,
        shadowColor: color.withOpacity(0.4),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  void _showNovedadesModal() async {
    final initService = ref.read(initServiceProvider);
    final novelties = await initService.getCachedNovelties();

    if (!mounted) return;

    if (novelties.isEmpty) {
      _showSnackBar(
          'No hay novedades disponibles.', Icons.info_outline, Colors.orange);
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Módulo de Novedad',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        content: SizedBox(
          width: 320,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: novelties.length,
            separatorBuilder: (_, __) =>
                const Divider(color: Colors.black12, height: 1),
            itemBuilder: (ctx, index) {
              final novedad = novelties[index];
              return ListTile(
                title: Text(novedad.name,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                trailing:
                    const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                onTap: () async {
                  Navigator.pop(ctx);

                  // Mostrar loading
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF6642F8))),
                  );

                  try {
                    await initService.sendNovelty(novedad.id, novedad.name);
                    if (mounted) Navigator.pop(context); // Cerrar loading
                    _showNovedadSuccess(novedad.name);
                  } catch (e) {
                    if (mounted) Navigator.pop(context); // Cerrar loading
                    _showSnackBar(
                        e.toString(), Icons.error_outline, Colors.redAccent);
                  }
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CERRAR',
                  style: TextStyle(
                      color: Colors.grey, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  void _showNovedadSuccess(String novedad) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded,
                color: Colors.green, size: 72),
            const SizedBox(height: 20),
            Text(
                'Hemos recibido tu solicitud de $novedad, la mesa de ayuda se comunicará contigo.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Color(0xFF3F3D56))),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6642F8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              child: const Text('ENTENDIDO',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(BalanceState balanceState) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6642F8), Color(0xFF4A2CB3)]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF6642F8).withOpacity(0.3),
              blurRadius: 15,
              offset: const Offset(0, 8))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Saldo del Punto de Venta',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          if (balanceState.status == BalanceStatus.loading)
            const CircularProgressIndicator(color: Colors.white70)
          else if (balanceState.status == BalanceStatus.error)
            Text(balanceState.errorMessage ?? 'Error',
                style: const TextStyle(color: Colors.white70))
          else
            Text('\$ ${_formatCurrency(balanceState.balance)}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5)),
          const SizedBox(height: 8),
          Text('Sucursal #${ref.read(authProvider).user?.branchId ?? "—"}',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.5), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildQrSaleCard(
      ProductsState productsState, QrPurchaseState qrState) {
    final isLoading = qrState.status == QrPurchaseStatus.loading;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                    color: const Color(0xFF6642F8).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.qr_code_scanner_rounded,
                    color: Color(0xFF6642F8), size: 24)),
            const SizedBox(width: 14),
            const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Venta Tickete',
                      style: TextStyle(
                          color: Color(0xFF3F3D56),
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  Text('Seleccione tarifa',
                      style: TextStyle(color: Colors.grey, fontSize: 12))
                ]),
          ]),
          const SizedBox(height: 32),
          if (isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  CircularProgressIndicator(color: Color(0xFF6642F8)),
                  SizedBox(height: 16),
                  Text('Procesando Venta...',
                      style: TextStyle(
                          color: Colors.grey, fontWeight: FontWeight.bold)),
                ],
              ),
            )
          else if (productsState.status == ProductsStatus.loading)
            const Center(
                child: CircularProgressIndicator(color: Color(0xFF6642F8)))
          else if (productsState.status == ProductsStatus.error)
            Text(productsState.errorMessage ?? 'Error',
                style: const TextStyle(color: Colors.redAccent))
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: productsState.products
                  .map((p) => _buildProductCard(p))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildProductCard(Product product) {
    IconData iconData;
    Color iconColor;
    final nameLower = product.productName.toLowerCase();

    if (product.pmr) {
      iconData = Icons.accessible_rounded;
      iconColor = Colors.blue;
    } else if (nameLower.contains('estudiante')) {
      iconData = Icons.school_rounded;
      iconColor = Colors.orange;
    } else if (nameLower.contains('adulto') || nameLower.contains('mayor')) {
      iconData = Icons.elderly_rounded;
      iconColor = Colors.teal;
    } else if (nameLower.contains('general') || nameLower.contains('normal')) {
      iconData = Icons.directions_bus_rounded;
      iconColor = const Color(0xFF6642F8);
    } else {
      iconData = Icons.confirmation_number_rounded;
      iconColor = const Color(0xFF6642F8);
    }

    return InkWell(
      onTap: () => _confirmPurchase(product),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 135,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, color: iconColor, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              product.productName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3F3D56),
                  fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '\$ ${_formatCurrency(product.value, showDecimals: false)}',
              style: const TextStyle(
                  color: Color(0xFF6642F8),
                  fontWeight: FontWeight.w900,
                  fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmPurchase(Product product) {
    int quantity = 1;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (innerContext, setInnerState) {
          final total = product.value * quantity;
          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.shopping_cart_checkout_rounded,
                    color: Color(0xFF6642F8)),
                SizedBox(width: 10),
                Text('Confirmar Venta',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style:
                        const TextStyle(color: Color(0xFF3F3D56), fontSize: 16),
                    children: [
                      const TextSpan(
                          text: '¿Deseas generar la venta para la tarifa\n'),
                      TextSpan(
                          text: '"${product.productName}"',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const TextSpan(text: '?'),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: quantity > 1
                          ? () => setInnerState(() => quantity--)
                          : null,
                      icon: Icon(Icons.remove_circle_outline,
                          color: quantity > 1 ? Colors.redAccent : Colors.grey,
                          size: 36),
                    ),
                    const SizedBox(width: 24),
                    Text('$quantity',
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 24),
                    IconButton(
                      onPressed: quantity < 20
                          ? () => setInnerState(() => quantity++)
                          : null,
                      icon: Icon(Icons.add_circle_outline,
                          color: quantity < 20 ? Colors.green : Colors.grey,
                          size: 36),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Total: \$ ${_formatCurrency(total, showDecimals: false)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF6642F8),
                      fontSize: 20),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('CANCELAR',
                      style: TextStyle(
                          color: Colors.grey, fontWeight: FontWeight.bold))),
              ElevatedButton(
                onPressed: () async {
                  // Guardamos una referencia segura al root navigator antes de cerrar el dialog
                  final navigator = Navigator.of(context, rootNavigator: true);

                  // Cerramos el dialog de confirmación
                  Navigator.pop(ctx);

                  // Abrimos el dialog de carga usando el context principal
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF6642F8))),
                  );

                  final isPrinterConnected = await ref
                      .read(systemStatusProvider.notifier)
                      .checkPrinterNow();

                  // Cerramos el dialog de carga usando el root navigator de forma segura
                  if (mounted) {
                    navigator.pop();
                  }

                  if (!isPrinterConnected) {
                    final proceed = await _showPrinterWarningDialog();
                    if (!proceed) return;
                  }

                  setState(() => _selectedProduct = product);
                  _processQrSaleMultiple(quantity);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6642F8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                child: const Text('CONFIRMAR VENTA'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _showPrinterWarningDialog() async {
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
          'No se ha detectado la impresora térmica.\n\n¿Deseas continuar y registrar esta operación sin imprimir el tiquete?',
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

  Widget _buildRecaudoSection() {
    // Aquí podrías envolver la pantalla de recaudo o llamarla directamente
    // Para simplificar, asumimos que RecaudoScreen es un widget separado que importamos
    return const RecaudoScreen();
  }

  String _formatCurrency(double value, {bool showDecimals = true}) {
    final parts = value.toStringAsFixed(showDecimals ? 2 : 0).split('.');
    final intPart = parts[0]
        .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return showDecimals && parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
  }

  void _processPmr() async {
    try {
      final dio = ref.read(dioProvider);
      await dio.post('http://192.168.1.100/open-pmr',
          options: Options(
              sendTimeout: const Duration(seconds: 1),
              receiveTimeout: const Duration(seconds: 1)));
    } catch (_) {
      print(
          'DEBUG: Endpoint PMR físico inalcanzable. Se omitió la apertura física.');
    }

    final db = await DatabaseHelper.instance.database;
    final branchId = ref.read(authProvider).user?.branchId ?? 0;
    final sessionQuery = await db.query('sessions',
        where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
    final sessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] : null;

    await db.insert('transactions', {
      'id': 'PMR-${DateTime.now().millisecondsSinceEpoch}',
      'session_id': sessionId,
      'product_id': 'PMR',
      'amount': 0,
      'pmr': 1,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
      'qr_data': 'PMR_MANUAL',
    });
    ref.read(salesHistoryProvider.notifier).fetchHistory();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Apertura PMR registrada exitosamente.'),
          backgroundColor: Colors.green));
    }
  }

  void _confirmPmr() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.accessible_rounded, color: Colors.blue),
          SizedBox(width: 10),
          Text('Apertura PMR', style: TextStyle(fontWeight: FontWeight.bold))
        ]),
        content: const Text(
            '¿Deseas enviar el comando de apertura manual al torniquete PMR?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCELAR',
                  style: TextStyle(
                      color: Colors.grey, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _processPmr();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('CONFIRMAR'),
          ),
        ],
      ),
    );
  }
}

class _ClockWidget extends StatefulWidget {
  const _ClockWidget({Key? key}) : super(key: key);
  @override
  __ClockWidgetState createState() => __ClockWidgetState();
}

class __ClockWidgetState extends State<_ClockWidget> {
  late Timer _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted)
        setState(() {
          _now = DateTime.now();
        });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${_now.day.toString().padLeft(2, '0')}/${_now.month.toString().padLeft(2, '0')}/${_now.year}';
    final timeStr =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    return Text('$dateStr $timeStr',
        style: const TextStyle(
            fontSize: 16,
            color: Color(0xFF6642F8),
            fontWeight: FontWeight.bold));
  }
}
