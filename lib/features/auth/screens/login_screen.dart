import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../providers/auth_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../widgets/location_selection_dialog.dart';
import '../../sales/services/closure_service.dart';
import '../../../core/database/database_helper.dart';
import '../../monitoring/services/system_status_service.dart';
import '../../../core/network/dio_client.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';
import 'package:app_settings/app_settings.dart';
import '../../../core/widgets/kiosk_logo_button.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/utils/device_utils.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _userFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  TextEditingController? _activeController;
  bool _obscurePassword = true;
  bool _hasUnclosedSales = false;
  String _macAddress = '';

  @override
  void initState() {
    super.initState();
    _activeController = _emailController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUnclosedSales();
      _loadMacAddress();
    });
    _userFocusNode.addListener(() {
      if (_userFocusNode.hasFocus) {
        setState(() => _activeController = _emailController);
      }
    });
    _passwordFocusNode.addListener(() {
      if (_passwordFocusNode.hasFocus) {
        setState(() => _activeController = _passwordController);
      }
    });

    Future.microtask(() {
      if (mounted) {
        ref.read(reviewerNameProvider.notifier).state = null;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
  }

  Future<void> _loadMacAddress() async {
    final mac = await DeviceUtils.getMacAddress();
    if (mounted) {
      setState(() {
        _macAddress = mac ?? 'Desconocida';
      });
    }
  }

  @override
  void dispose() {
    _userFocusNode.dispose();
    _passwordFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _checkUnclosedSales() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.query(
        'transactions',
        where: 'is_closed = 0 AND product_id != ? AND product_id != ?',
        whereArgs: ['CIERRE DE CAJA', 'APERTURA DE CAJA'],
        limit: 1,
      );
      if (mounted) {
        setState(() {
          _hasUnclosedSales = result.isNotEmpty;
        });
      }
    } catch (_) {}
  }

  Future<void> _showPendingSalesModal() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.rawQuery('''
        SELECT 
          u.name, 
          COUNT(t.local_id) as pending_count, 
          SUM(t.amount) as pending_amount
        FROM transactions t
        LEFT JOIN users u ON t.cashier_id = u.id
        WHERE t.is_closed = 0 AND t.product_id != 'CIERRE DE CAJA' AND t.product_id != 'APERTURA DE CAJA' AND t.product_id != 'PMR' AND t.product_id != 'INGRESO_FISCALIZADOR'
        GROUP BY t.cashier_id
        HAVING pending_count > 0
      ''');

      if (mounted) Navigator.pop(context); // quitar loader

      if (result.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'La caja está limpia. Ningún usuario tiene ventas pendientes de cierre.'),
            backgroundColor: Colors.green,
          ));
        }
        return;
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.account_balance_wallet_rounded,
                    color: Colors.orange, size: 28),
                SizedBox(width: 12),
                Text('Ventas Pendientes por Usuario',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              ],
            ),
            content: SizedBox(
              width: 450,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: result.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (ctx, i) {
                  final row = result[i];
                  final name = row['name']?.toString() ?? 'Cajero Desconocido';
                  final count = row['pending_count'] as int? ?? 0;
                  final amount =
                      (row['pending_amount'] as num?)?.toDouble() ?? 0;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Color(0xFF3F3D56))),
                    subtitle: Text('Ventas sin cerrar: $count'),
                    trailing: Text(
                        '\$${amount.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: Color(0xFF6642F8),
                            fontWeight: FontWeight.bold,
                            fontSize: 18)),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ENTENDIDO',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    
    // Limpiar cualquier estado residual de fiscalizador ANTES de iniciar sesión con un usuario normal
    ref.read(reviewerNameProvider.notifier).state = null;
    
    await ref.read(authProvider.notifier).login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );

    final authState = ref.read(authProvider);
    // Si llegamos aquí sin excepción, solicitamos el Punto de Venta
    if (mounted && authState.status == AuthStatus.authenticated) {
      // 1. (Eliminado: Petición directa al servidor RC171 para evitar duplicidad, ahora se encola abajo)

      // 2. Capturar y guardar GPS (Solo se pide una vez al iniciar sesión)
      try {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (serviceEnabled) {
          LocationPermission permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission == LocationPermission.whileInUse ||
              permission == LocationPermission.always) {
            Position position = await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.medium);
            await ref
                .read(localStorageProvider)
                .saveGpsLocation(position.latitude, position.longitude);
            print(
                'DEBUG: GPS capturado en login: ${position.latitude}, ${position.longitude}');
          }
        }
      } catch (e) {
        print('DEBUG: Error capturando GPS en login: $e');
      }

      // 3. Pedimos punto de venta (UI)
      final success = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const LocationSelectionDialog(),
      );

      if (mounted) {
        if (success == true) {
          // 4. Guardamos la transacción offline de Apertura de Caja para que se sincronice en la RC171
          try {
            final db = await DatabaseHelper.instance.database;
            final posLocationId =
                await ref.read(localStorageProvider).getPosLocationId();
            final gpsData =
                await ref.read(localStorageProvider).getGpsLocation();
            final cashierId = authState.user?.id ?? 1;

            final random = math.Random();
            final plotIdBytes = List<int>.generate(16, (i) => random.nextInt(256));
            final plotId = md5.convert(plotIdBytes).toString();

            await db.insert('transactions', {
              'id':
                  'open-${DateTime.now().microsecondsSinceEpoch}-$posLocationId',
              'session_id': null,
              'cashier_id': cashierId,
              'pos_location_id': posLocationId,
              'product_id': 'APERTURA DE CAJA',
              'amount': 0.0,
              'pmr': 0,
              'status': 'pending',
              'created_at': DateTime.now().toIso8601String(),
              'qr_data': '', // Token vacío
              'print_status': 0,
              'lat': gpsData?['lat'],
              'lon': gpsData?['lon'],
              'plot_id': plotId,
            });
            print(
                'DEBUG: Transacción de APERTURA DE CAJA guardada localmente para desencole (RC174).');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Caja abierta offline exitosamente (RC174)'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          } catch (e) {
            print('DEBUG: Error al guardar APERTURA DE CAJA: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error guardando RC174: $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }

          Navigator.pushReplacementNamed(context, '/dashboard');
        } else {
          // Si el usuario cancela, cerramos la sesión parcial
          await ref.read(authProvider.notifier).logout(ref);
        }
      }
    }
  }

  Future<void> _printLastClosure() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Ingresa tu usuario y contraseña para autorizar la impresión',
              style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    print('DEBUG: Iniciando _printLastClosure con validación de usuario...');
    final printer = ref.read(printerServiceProvider);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF6642F8)),
                SizedBox(height: 16),
                Text('Validando y buscando cierre...',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );

    // 1. Validar Credenciales
    await ref.read(authProvider.notifier).login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );

    final authState = ref.read(authProvider);
    if (authState.status != AuthStatus.authenticated) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Credenciales incorrectas o sin red',
                style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // 2. Proceder con la impresión
    bool success = false;
    String errorMessage = 'No hay cierres guardados';

    try {
      final db = await DatabaseHelper.instance.database;
      final results = await db.query(
        'transactions',
        where: 'product_id = ?',
        whereArgs: ['CIERRE DE CAJA'],
        orderBy: 'created_at DESC',
        limit: 1,
      );

      if (results.isNotEmpty) {
        final closure = results.first;
        final qrData = closure['qr_data']?.toString() ?? '';
        final jsonStr = utf8.decode(base64Decode(qrData));
        final data = jsonDecode(jsonStr);
        final sessionId = closure['session_id'];
        final cashierId = closure['cashier_id'];
        final createdAt = closure['created_at'];

        // Cargar nombres de productos
        final productsQuery = await db.query('products');
        final Map<String, String> productNames = {
          for (var p in productsQuery) p['id'].toString(): p['product_name']?.toString() ?? "Tarifa \${p['id']}"
        };

        // 1. Reconstruir desglose del cajero (Breakdown)
        // Buscamos si hubo un cierre anterior en la misma sesión para este cajero
        final previousClosure = await db.query(
          'transactions',
          where: 'session_id = ? AND cashier_id = ? AND product_id = ? AND created_at < ?',
          whereArgs: [sessionId, cashierId, 'CIERRE DE CAJA', createdAt],
          orderBy: 'created_at DESC',
          limit: 1,
        );
        String? previousCreatedAt;
        if (previousClosure.isNotEmpty) {
           previousCreatedAt = previousClosure.first['created_at']?.toString();
        }

        String breakdownWhere = 'session_id = ? AND cashier_id = ? AND product_id != ? AND product_id != ? AND product_id != ? AND created_at <= ?';
        List<Object?> breakdownArgs = [sessionId, cashierId, 'CIERRE DE CAJA', 'APERTURA DE CAJA', 'INGRESO_FISCALIZADOR', createdAt];
        
        if (previousCreatedAt != null) {
          breakdownWhere += ' AND created_at > ?';
          breakdownArgs.add(previousCreatedAt);
        }

        final unclosedSales = await db.query(
          'transactions', 
          where: breakdownWhere, 
          whereArgs: breakdownArgs
        );
        
        Map<String, int> breakdownQty = {};
        Map<String, double> breakdownTotal = {};
        for (final sale in unclosedSales) {
          if (sale['product_id'] == 'PMR') continue;
          final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
          final productId = sale['product_id']?.toString() ?? 'Desc.';
          breakdownQty[productId] = (breakdownQty[productId] ?? 0) + 1;
          breakdownTotal[productId] = (breakdownTotal[productId] ?? 0) + amount;
        }

        List<String> breakdownLines = [];
        breakdownQty.forEach((pId, qty) {
          final t = breakdownTotal[pId] ?? 0;
          final pName = productNames[pId] ?? 'Tarifa $pId';
          final qtyStr = '${qty}x'.padRight(4);
          final nameStr = pName.length > 15 ? pName.substring(0, 15) : pName.padRight(15);
          final valStr = '\$${CurrencyFormatter.format(t)}'.padLeft(8);
          breakdownLines.add('$qtyStr $nameStr $valStr');
        });

        // 2. Reconstruir Resumen del Día (Arrastre)
        final allSales = await db.query(
          'transactions', 
          where: 'session_id = ? AND product_id != ? AND product_id != ? AND product_id != ? AND created_at <= ?', 
          whereArgs: [sessionId, 'CIERRE DE CAJA', 'APERTURA DE CAJA', 'INGRESO_FISCALIZADOR', createdAt]
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
          final t = dayBreakdownTotal[pId] ?? 0;
          final pName = productNames[pId] ?? 'Tarifa $pId';
          final qtyStr = '${qty}x'.padRight(4);
          final nameStr = pName.length > 15 ? pName.substring(0, 15) : pName.padRight(15);
          final valStr = '\$${CurrencyFormatter.format(t)}'.padLeft(8);
          dayBreakdownLines.add('$qtyStr $nameStr $valStr');
        });

        final daySummary = {
          'totalTransactions': dayCount,
          'totalAmount': dayTotalAmount,
          'breakdown': dayBreakdownLines
        };

        Map<String, dynamic>? cashList;
        if (data.containsKey('coins_total') && data.containsKey('bills_total')) {
          cashList = {
            'coins_total': data['coins_total'],
            'bills_total': data['bills_total'],
          };
        }
        final double? cash = data['cash'] != null ? (data['cash'] as num).toDouble() : null;
        final double? balance = data['balance'] != null ? (data['balance'] as num).toDouble() : null;

        final userEmail = ref.read(authProvider).user?.email ?? '01';
        final currentUserCode = userEmail.split('@').first;

        bool shouldPrintBreakdown = false;
        if (cashList == null && cash == null) {
          // Si no hay cash ni cashList, fue fiscalizador
          shouldPrintBreakdown = true;
        } else if (cash != null && cash > 0) {
          // Si hay cash y es mayor a 0, fue un cajero con efectivo
          shouldPrintBreakdown = true;
        }

        final printResult = await printer.printClosingTicket(
          cashierName: data['c']?.toString() ?? 'Operador',
          cashierId: currentUserCode,
          branchName: 'Sucursal',
          totalTransactions: data['q'] ?? 0,
          totalAmount: (data['a'] as num?)?.toDouble() ?? 0,
          startTime: 'Turno',
          endTime: '${data["d"]} ${data["t"] ?? ""}',
          qrData: qrData,
          breakdown: shouldPrintBreakdown ? breakdownLines : null,
          pmrCount: data['pmr_q'] ?? 0,
          reprintsCount: 1,
          daySummary: daySummary,
          cashList: cashList,
          cash: cash,
          balance: balance,
        );
        success = printResult ?? false;

        if (printResult == null) {
          errorMessage = 'Acepta el permiso USB e intenta de nuevo';
        } else if (!success) {
          errorMessage = 'Error: No se detectó impresora USB';
        }
      }
    } catch (e) {
      errorMessage = 'Error al leer el cierre: $e';
    }

    // 3. Cerrar sesión automáticamente tras autorizar la impresión
    await ref.read(authProvider.notifier).logout(ref);

    if (mounted) Navigator.of(context).pop();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(success ? '¡Cierre impreso exitosamente!' : errorMessage),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _showSupportOptions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Opciones de Soporte',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Seleccione una opción de soporte administrativo:'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              AppSettings.openAppSettings();
            },
            child: const Text('Ajustes del Sistema'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _exportTransactions();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6642F8),
                foregroundColor: Colors.white),
            child: const Text('Exportar Tramas a TXT'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportTransactions() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final db = await DatabaseHelper.instance.database;
      final txs = await db.query('transactions');

      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final sb = StringBuffer();
      sb.writeln('=== EXPORTACIÓN DE TRAMAS ===');
      sb.writeln('Fecha: ${DateTime.now().toIso8601String()}');
      sb.writeln('Total registros: ${txs.length}');
      sb.writeln('==============================\n');
      
      for (final tx in txs) {
        sb.writeln(jsonEncode(tx));
      }
      
      File? file;
      String finalPath = '';
      
      try {
        // Opción 1: Carpeta de descargas pública
        final Directory downDir = Directory('/storage/emulated/0/Download');
        if (downDir.existsSync()) {
          file = File('${downDir.path}/tramas_exportadas.txt');
          await file.writeAsString(sb.toString());
          finalPath = file.path;
        } else {
          throw Exception('Download no existe');
        }
      } catch (e) {
        // Opción 2: Carpeta pública de la app en Android/data/ (Visible al conectar por USB o gestores de archivos)
        try {
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            file = File('${extDir.path}/tramas_exportadas.txt');
            await file.writeAsString(sb.toString());
            finalPath = file.path;
          } else {
            throw Exception('Directorio externo no disponible');
          }
        } catch (e2) {
          // Opción 3: Carpeta interna estricta (invisible sin root)
          final appDir = await getApplicationDocumentsDirectory();
          file = File('${appDir.path}/tramas_exportadas.txt');
          await file.writeAsString(sb.toString());
          finalPath = file.path;
        }
      }
      
      if (mounted) {
        Navigator.pop(context); // Cerrar loader
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Tramas Guardadas'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Archivo guardado en:', style: const TextStyle(fontWeight: FontWeight.bold)),
                    SelectableText(finalPath, style: const TextStyle(color: Colors.blue)),
                    const SizedBox(height: 10),
                    const Divider(),
                    const Text('Contenido:'),
                    const SizedBox(height: 10),
                    SelectableText(sb.toString()),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('CERRAR'),
              )
            ],
          )
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error al exportar: $e', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  void _onNumPadTap(String value) {
    if (_activeController == null) return;
    final text = _activeController!.text;
    if (value == 'C') {
      _activeController!.clear();
    } else if (value == '⌫') {
      if (text.isNotEmpty) {
        _activeController!.text = text.substring(0, text.length - 1);
      }
    } else {
      _activeController!.text += value;
    }
  }

  Widget _buildNumPad(AuthState authState) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Column(
        children: [
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.3,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 1; i <= 9; i++) _buildNumButton(i.toString()),
              _buildNumButton('C', color: Colors.redAccent),
              _buildNumButton('0'),
              _buildNumButton('⌫', icon: Icons.backspace_outlined),
            ],
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: authState.status == AuthStatus.loading ? null : _login,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 64),
              backgroundColor: const Color(0xFF6642F8),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: authState.status == AuthStatus.loading
                ? const SizedBox(
                    height: 28,
                    width: 28,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 3))
                : const Text('INICIAR SESIÓN',
                    style: TextStyle(
                        fontSize: 22, // Aumentado de 18 a 22
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1)),
          ),
        ],
      ),
    );
  }

  Widget _buildNumButton(String label, {IconData? icon, Color? color}) {
    return Material(
      color: color?.withOpacity(0.1) ?? Colors.grey.shade100,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _onNumPadTap(label),
        child: Center(
          child: icon != null
              ? Icon(icon, color: color ?? const Color(0xFF3F3D56), size: 28)
              : Text(label,
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: color ?? const Color(0xFF3F3D56))),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final authState = ref.watch(authProvider);

    return Form(
      key: _formKey,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: KioskLogoButton(
              pin: '9999',
              requiredTaps: 3,
              onSuccess: _showSupportOptions,
              child: Image.asset(
                'assets/valliu-logo.png',
                height: 90,
                errorBuilder: (ctx, err, stack) => Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6642F8).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.point_of_sale_rounded,
                      color: Color(0xFF6642F8), size: 40),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Bienvenido a Juana',
            style: TextStyle(
              fontSize: 32, // Aumentado de 26 a 32
              fontWeight: FontWeight.w900,
              color: Color(0xFF3F3D56),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inicia sesión con tu código',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.grey, fontSize: 18), // Aumentado de 15 a 18
          ),
          const SizedBox(height: 36),
          TextFormField(
            controller: _emailController,
            focusNode: _userFocusNode,
            readOnly: true,
            showCursor: true,
            onTap: () => setState(() => _activeController = _emailController),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: 'Usuario / Identificación',
              prefixIcon: const Icon(Icons.person_outline),
              filled: _activeController == _emailController,
              fillColor: const Color(0xFF6642F8).withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: Color(0xFF6642F8), width: 2),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Requerido';
              if (v.length < 4) return 'Mínimo 4 caracteres';
              return null;
            },
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            readOnly: true,
            showCursor: true,
            obscureText: _obscurePassword,
            onTap: () =>
                setState(() => _activeController = _passwordController),
            style: const TextStyle(
                fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: 'Contraseña',
              prefixIcon: const Icon(Icons.lock_outline),
              filled: _activeController == _passwordController,
              fillColor: const Color(0xFF6642F8).withOpacity(0.05),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: Color(0xFF6642F8), width: 2),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Requerido';
              if (v.length < 4) return 'Mínimo 4 caracteres';
              return null;
            },
          ),
          if (authState.errorMessage != null) ...[
            const SizedBox(height: 24),
            Text(
              'Error (${authState.errorMessage})',
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final systemStatus = ref.watch(systemStatusProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _showPendingSalesModal,
            tooltip: _hasUnclosedSales
                ? 'Ver ventas pendientes de cierre'
                : 'No hay ventas pendientes',
            icon: Icon(
              Icons.account_balance_wallet_rounded,
              color: _hasUnclosedSales ? Colors.redAccent : Colors.green,
              size: 40,
            ),
          ),
          const SizedBox(width: 16),
          Icon(Icons.accessible_rounded,
              color:
                  systemStatus.isPmrConnected ? Colors.green : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.camera_alt_rounded,
              color: systemStatus.isCameraConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.print_rounded,
              color: systemStatus.isPrinterConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.wifi_rounded,
              color: systemStatus.isInternetConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          if (systemStatus.pendingTransactions > 0)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(16)),
                child: Text('${systemStatus.pendingTransactions}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _printLastClosure,
        backgroundColor: const Color(0xFF6642F8),
        tooltip: 'Imprimir último cierre',
        child: const Icon(Icons.point_of_sale_rounded, color: Colors.white),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth > 800) {
                  // Pantalla grande: Mostrar en dos columnas (Row)
                  return Center(
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            flex: 5,
                            child: SingleChildScrollView(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 32),
                                child: _buildForm(),
                              ),
                            ),
                          ),
                          Container(
                              width: 1, height: 400, color: Colors.grey.shade200),
                          Expanded(
                            flex: 6,
                            child: Center(
                              child: SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 32),
                                  child: _buildNumPad(authState),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                } else {
                  // Pantalla pequeña: Mostrar en una sola columna (Column)
                  return Center(
                    child: SingleChildScrollView(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildForm(),
                          const SizedBox(height: 48),
                          _buildNumPad(authState),
                        ],
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          Positioned(
            bottom: 16,
            left: 16,
            child: Text(
              '${ApiConstants.displayVersion} - MAC: ${_macAddress.isEmpty ? 'Cargando...' : _macAddress}',
              style: const TextStyle(
                color: Colors.black54,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
