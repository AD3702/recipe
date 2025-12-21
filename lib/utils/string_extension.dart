import 'dart:convert';

import 'package:crypto/crypto.dart';

extension StringExtension on String {
  String get encryptPassword {
    return md5.convert(utf8.encode(this)).toString();
  }

  String get encryptBasic {
    String basic = this;
    int i = 0;
    while (i < 8) {
      basic = base64Encode(utf8.encode(basic));
      i++;
    }
    return basic;
  }

  String get decryptBasic {
    String basic = this;
    int i = 0;
    while (i < 8) {
      basic = utf8.decode(base64Decode(basic));
      i++;
    }
    return basic;
  }

  /// Convert snake_case to camelCase
  String get snakeToCamel {
    return split('_').mapIndexed((index, word) {
      if (index == 0) return word.toLowerCase();
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join();
  }

  /// Convert camelCase to snake_case
  String get camelToSnake {
    return replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) => '${match.group(1)}_${match.group(2)}').toLowerCase();
  }

  /// Recursively convert all map keys from camelCase to snake_case
  dynamic convertKeysToSnakeCase(dynamic data) {
    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString().camelToSnake, convertKeysToSnakeCase(value)));
    } else if (data is List) {
      return data.map((e) => convertKeysToSnakeCase(e)).toList();
    }
    return data;
  }

  /// Main function: decode -> convert -> encode
  String get convertJsonCamelToSnake {
    final decoded = jsonDecode(this);
    final converted = convertKeysToSnakeCase(decoded);
    return jsonEncode(converted);
  }
}

/// Extension for using mapIndexed easily
extension IterableMapIndexed<E> on Iterable<E> {
  Iterable<T> mapIndexed<T>(T Function(int index, E e) f) sync* {
    int index = 0;
    for (final element in this) {
      yield f(index, element);
      index++;
    }
  }
}
