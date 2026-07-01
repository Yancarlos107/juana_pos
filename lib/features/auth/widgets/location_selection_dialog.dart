import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/network/dio_client.dart';
import '../../sync/services/init_service.dart';
import '../models/pos_location_model.dart';
import '../providers/auth_providers.dart';

class LocationSelectionDialog extends ConsumerStatefulWidget {
  const LocationSelectionDialog({super.key});

  @override
  ConsumerState<LocationSelectionDialog> createState() => _LocationSelectionDialogState();
}

class _LocationSelectionDialogState extends ConsumerState<LocationSelectionDialog> {
  bool _isLoading = true;
  List<PosLocationModel> _locations = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final initService = ref.read(initServiceProvider);
      final data = await initService.initializePOS();

      // Si el servidor nos asignó automáticamente una ubicación, no hace falta que el usuario escoja
      if (data['auto_assigned_location'] == true) {
        if (mounted) {
          Navigator.of(context).pop(true);
        }
        return;
      }

      List<PosLocationModel> loadedLocations = List.from(data['locations'] as List<PosLocationModel>);
      
      // Mover al principio la sucursal del usuario actual
      final authState = ref.read(authProvider);
      final userBranchId = authState.user?.branchId;
      
      if (userBranchId != null) {
        final userLocationIndex = loadedLocations.indexWhere((loc) => loc.id == userBranchId);
        if (userLocationIndex != -1) {
          final userLocation = loadedLocations.removeAt(userLocationIndex);
          loadedLocations.insert(0, userLocation);
        }
      }

      setState(() {
        _locations = loadedLocations;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _selectLocation(PosLocationModel location) async {
    setState(() => _isLoading = true);
    try {
      final initService = ref.read(initServiceProvider);
      await initService.updatePosSchedule(location.id);

      final storage = ref.read(localStorageProvider);
      await storage.savePosLocationId(location.id);
      await storage.savePosLocationName(location.name);
      
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isLoading ? 'Sincronizando datos...' : 'Seleccionar Punto de Venta',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF3F3D56),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (_isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: CircularProgressIndicator(color: Color(0xFF6642F8)),
                ),
              )
            else if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _errorMessage!.contains('offline_no_cache')
                          ? 'Error al descargar datos iniciales. Por favor, cierra la aplicación, verifica tu conexión a internet y vuelve a intentarlo.'
                          : 'Error al sincronizar:\n$_errorMessage',
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        if (mounted) {
                          Navigator.of(context).pop(false);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('CERRAR', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              )
            else if (_locations.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: Text('No hay puntos de venta disponibles.'),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _locations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final location = _locations[index];
                    final isUserBranch = ref.read(authProvider).user?.branchId == location.id;
                    return InkWell(
                      onTap: () => _selectLocation(location),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        decoration: BoxDecoration(
                          border: Border.all(color: isUserBranch ? Colors.blue.shade300 : Colors.grey.shade300, width: isUserBranch ? 2 : 1),
                          borderRadius: BorderRadius.circular(12),
                          color: isUserBranch ? Colors.blue.shade50 : Colors.white,
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isUserBranch ? Colors.blue.withOpacity(0.2) : const Color(0xFF6642F8).withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isUserBranch ? Icons.person_pin_circle_rounded : Icons.storefront_rounded,
                                color: isUserBranch ? Colors.blue.shade700 : const Color(0xFF6642F8),
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    location.name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: isUserBranch ? Colors.blue.shade900 : const Color(0xFF3F3D56),
                                    ),
                                  ),
                                  if (isUserBranch)
                                    Text(
                                      'Punto Asignado',
                                      style: TextStyle(color: Colors.blue.shade700, fontSize: 12, fontWeight: FontWeight.bold),
                                    )
                                ],
                              ),
                            ),
                            const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey.shade800,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('CANCELAR', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
