import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../widgets/location_selection_dialog.dart';
import '../../sales/services/closure_service.dart';
import '../../../core/database/database_helper.dart';
import '../../monitoring/services/system_status_service.dart';
import 'dart:convert';

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

  @override
  void initState() {
    super.initState();
    _activeController = _emailController;
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
  }

  @override
  void dispose() {
    _userFocusNode.dispose();
    _passwordFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(authProvider.notifier).login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );

    final authState = ref.read(authProvider);
    // Si llegamos aquí sin excepción, solicitamos el Punto de Venta
    if (mounted && authState.status == AuthStatus.authenticated) {
      // 1. Abrimos la caja en el servidor (RC171)
      try {
        final closureService = ref.read(closureServiceProvider);
        await closureService.openRegister(authState.user!.name);
      } catch (e) {
        print('Advertencia: No se pudo abrir la caja en el backend: $e');
      }

      // 2. Pedimos punto de venta (UI)
      final success = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const LocationSelectionDialog(),
      );

      if (mounted) {
        if (success == true) {
          Navigator.pushReplacementNamed(context, '/dashboard');
        } else {
          // Si el usuario cancela, cerramos la sesión parcial
          await ref.read(authProvider.notifier).logout();
        }
      }
    }
  }

  Future<void> _printLastClosure() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ingresa tu usuario y contraseña para autorizar la impresión', style: TextStyle(fontWeight: FontWeight.bold)),
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
            content: Text('Credenciales incorrectas o sin red', style: TextStyle(fontWeight: FontWeight.bold)),
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
        final qrData = results.first['qr_data']?.toString() ?? '';
        final jsonStr = utf8.decode(base64Decode(qrData));
        final data = jsonDecode(jsonStr);

        final printResult = await printer.printClosingTicket(
          cashierName: data['c']?.toString() ?? 'Operador',
          branchName: 'Sucursal',
          totalTransactions: data['q'] ?? 0,
          totalAmount: (data['a'] as num?)?.toDouble() ?? 0,
          startTime: 'Turno',
          endTime: data['d']?.toString() ?? '',
          qrData: qrData,
          pmrCount: data['pmr_q'] ?? 0,
          reprintsCount: 1,
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
    await ref.read(authProvider.notifier).logout();

    if (mounted) Navigator.of(context).pop();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '¡Cierre impreso exitosamente!' : errorMessage),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
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
            style: TextStyle(color: Colors.grey, fontSize: 18), // Aumentado de 15 a 18
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
            style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
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
          Icon(Icons.accessible_rounded,
              color: systemStatus.isPmrConnected ? Colors.green : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.camera_alt_rounded,
              color: systemStatus.isCameraConnected ? Colors.green : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.print_rounded,
              color: systemStatus.isPrinterConnected ? Colors.green : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.wifi_rounded,
              color: systemStatus.isInternetConnected ? Colors.green : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          if (systemStatus.pendingTransactions > 0)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
      body: SafeArea(
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
    );
  }
}
