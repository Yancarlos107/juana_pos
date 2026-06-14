import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// Descifra el contenido del QR de login ("usuario#clave") cifrado con DES
/// y la llave "juana-777".
///
/// PointyCastle no registra un motor DES de bloque simple (solo "DESede" /
/// Triple DES), así que se usa DESede con la misma llave de 8 bytes repetida
/// 3 veces (K1=K2=K3), lo cual es matemáticamente equivalente a DES simple.
///
/// Como no se conoce con certeza el formato exacto que genera el área de
/// desarrollo, se prueban varias combinaciones (hex/base64, con/sin salt
/// OpenSSL, CBC/ECB) y se devuelve la primera que produzca un texto con "#".
class CryptoUtils {
  static final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

  static String decryptLoginQR(String rawInput, String passphrase) {
    final input = rawInput.trim();
    final candidates = <Uint8List>[];

    if (input.isNotEmpty && input.length % 2 == 0 && _hexPattern.hasMatch(input)) {
      candidates.add(_hexDecode(input));
    }
    try {
      candidates.add(_base64Decode(input));
    } catch (_) {}

    if (candidates.isEmpty) {
      throw Exception('El contenido del QR no es hexadecimal ni base64 válido.');
    }

    final errors = <String>[];
    final directKey = _normalizeKey(passphrase);

    for (final bytes in candidates) {
      // Formato OpenSSL: "Salted__" (8 bytes) + salt (8 bytes) + cifrado
      if (bytes.length > 16 && _hasSaltedPrefix(bytes)) {
        final salt = bytes.sublist(8, 16);
        final encrypted = bytes.sublist(16);

        try {
          final keyIv = _evpKDF(utf8.encode(passphrase), salt, 16);
          final result = _tryDecryptCbc(encrypted, keyIv.sublist(0, 8), keyIv.sublist(8, 16));
          if (result != null) return result;
        } catch (e) {
          errors.add('EvpKDF+CBC: $e');
        }

        // Iteraciones de PBKDF2: la herramienta de generación no muestra el
        // valor exacto, se prueban los más comunes en herramientas online.
        for (final iterations in [1, 1000, 10000]) {
          try {
            final keyIv = _pbkdf2(passphrase, salt, iterations, 16);
            final result = _tryDecryptCbc(encrypted, keyIv.sublist(0, 8), keyIv.sublist(8, 16));
            if (result != null) return result;
          } catch (e) {
            errors.add('PBKDF2($iterations)+CBC: $e');
          }
        }
      }

      // Sin salt: llave fija (primeros 8 bytes de la passphrase)
      try {
        final result = _tryDecryptCbc(bytes, directKey, Uint8List(8));
        if (result != null) return result;
      } catch (e) {
        errors.add('Llave directa+CBC: $e');
      }

      try {
        final result = _tryDecryptEcb(bytes, directKey);
        if (result != null) return result;
      } catch (e) {
        errors.add('Llave directa+ECB: $e');
      }
    }

    throw Exception('No se pudo descifrar el QR. Intentos: ${errors.join(' | ')}');
  }

  static bool _hasSaltedPrefix(Uint8List bytes) {
    final prefix = utf8.encode('Salted__');
    for (int i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static String? _tryDecryptCbc(Uint8List data, Uint8List key8, Uint8List iv) {
    if (data.isEmpty || data.length % 8 != 0) return null;
    try {
      final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(DESedeEngine()));
      cipher.init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(_tripleKey(key8)), iv),
          null,
        ),
      );
      final decrypted = utf8.decode(cipher.process(data));
      return decrypted.contains('#') ? decrypted : null;
    } catch (_) {
      return null;
    }
  }

  static String? _tryDecryptEcb(Uint8List data, Uint8List key8) {
    if (data.isEmpty || data.length % 8 != 0) return null;
    try {
      final cipher = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(DESedeEngine()));
      cipher.init(
        false,
        PaddedBlockCipherParameters<KeyParameter, Null>(KeyParameter(_tripleKey(key8)), null),
      );
      final decrypted = utf8.decode(cipher.process(data));
      return decrypted.contains('#') ? decrypted : null;
    } catch (_) {
      return null;
    }
  }

  /// Repite la llave DES de 8 bytes 3 veces (K1=K2=K3 => Triple DES == DES simple).
  static Uint8List _tripleKey(Uint8List key8) => Uint8List.fromList([...key8, ...key8, ...key8]);

  /// Primeros 8 bytes de la passphrase (rellenando con ceros si es más corta).
  static Uint8List _normalizeKey(String passphrase) {
    final bytes = utf8.encode(passphrase);
    final key = Uint8List(8);
    for (int i = 0; i < 8 && i < bytes.length; i++) {
      key[i] = bytes[i];
    }
    return key;
  }

  /// EvpKDF: KDF legado de OpenSSL/CryptoJS (MD5, 1 iteración).
  static Uint8List _evpKDF(List<int> password, Uint8List salt, int keySize) {
    final md5 = MD5Digest();
    var current = Uint8List(0);
    final derived = BytesBuilder();

    while (derived.length < keySize) {
      md5.reset();
      md5.update(current, 0, current.length);
      md5.update(Uint8List.fromList(password), 0, password.length);
      md5.update(salt, 0, salt.length);

      final out = Uint8List(16);
      md5.doFinal(out, 0);
      current = out;
      derived.add(current);
    }

    return derived.toBytes().sublist(0, keySize);
  }

  static Uint8List _pbkdf2(String passphrase, Uint8List salt, int iterations, int keySize) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, keySize));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static Uint8List _hexDecode(String hexStr) {
    final result = Uint8List(hexStr.length ~/ 2);
    for (int i = 0; i < hexStr.length; i += 2) {
      result[i ~/ 2] = int.parse(hexStr.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  static Uint8List _base64Decode(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    return base64Decode(s);
  }
}
