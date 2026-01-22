import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:recipe/utils/list_extenstion.dart';
import 'package:recipe/utils/config.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_multipart/shelf_multipart.dart';

class DBFunctions {
  DBFunctions._();

  static Future<void> createTableFromClass(Connection connection, String tableName, Map<String, dynamic> sampleJson) async {
    final columns = sampleJson.entries
        .map((entry) {
          final sqlType = entry.key == 'id' ? 'INTEGER PRIMARY KEY' : dartTypeToSQL(entry.value);
          return '${entry.key} $sqlType';
        })
        .join(', ');
    final createQuery = 'CREATE TABLE IF NOT EXISTS "$tableName" ($columns);';
    var res = await connection.execute(createQuery);
    // Fetch existing columns safely
    final result = await connection.execute("SELECT column_name FROM information_schema.columns WHERE table_name = '$tableName' ORDER BY ordinal_position");
    final existingColumns = result.map((row) => row[0] as String).toSet();
    // Also fetch existing column types
    final typeResult = await connection.execute("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = '$tableName' ORDER BY ordinal_position");
    final Map<String, String> existingTypes = {for (final row in typeResult) (row[0] as String): (row[1] as String)};
    // Add missing columns and alter wrong types except 'id'
    for (var entry in sampleJson.entries) {
      if (entry.key == 'id') continue; // don't alter id column

      final colName = entry.key;
      final desiredSqlType = dartTypeToSQL(entry.value);

      // 1) Add missing column
      if (!existingColumns.contains(colName)) {
        final alterQuery = 'ALTER TABLE "$tableName" ADD COLUMN "$colName" $desiredSqlType;';
        await connection.execute(alterQuery);
        continue;
      }

      // 2) Alter wrong type
      final existingInfoType = existingTypes[colName];
      if (existingInfoType == null) continue;

      final desiredInfoType = _sqlTypeToInfoSchemaType(desiredSqlType);
      if (desiredInfoType == null) continue;

      if (_normalizeInfoSchemaType(existingInfoType) != _normalizeInfoSchemaType(desiredInfoType)) {
        final alterType = _sqlTypeToAlterType(desiredSqlType);
        final alterTypeQuery = 'ALTER TABLE "$tableName" ALTER COLUMN "$colName" TYPE $alterType USING "$colName"::$alterType;';
        await connection.execute(alterTypeQuery);
      }
    }
  }

  static String _normalizeInfoSchemaType(String t) {
    return t.trim().toLowerCase();
  }

  /// Map our SQL type strings to information_schema.data_type values.
  /// (info_schema uses values like: integer, text, boolean, double precision,
  /// timestamp without time zone, timestamp with time zone)
  static String? _sqlTypeToInfoSchemaType(String sqlType) {
    final t = sqlType.trim().toUpperCase();
    if (t == 'INTEGER' || t.startsWith('INTEGER ')) return 'integer';
    if (t == 'TEXT' || t.startsWith('TEXT ')) return 'text';
    if (t == 'BOOLEAN' || t.startsWith('BOOLEAN ')) return 'boolean';
    if (t == 'DOUBLE PRECISION' || t.startsWith('DOUBLE PRECISION ')) return 'double precision';
    if (t == 'TIMESTAMP' || t.startsWith('TIMESTAMP ')) return 'timestamp without time zone';
    return null;
  }

  /// Map our SQL type strings to a safe ALTER TYPE target.
  static String _sqlTypeToAlterType(String sqlType) {
    final t = sqlType.trim().toUpperCase();
    if (t.startsWith('INTEGER')) return 'INTEGER';
    if (t.startsWith('TEXT')) return 'TEXT';
    if (t.startsWith('BOOLEAN')) return 'BOOLEAN';
    if (t.startsWith('DOUBLE PRECISION')) return 'DOUBLE PRECISION';
    if (t.startsWith('TIMESTAMP')) return 'TIMESTAMP';
    return 'TEXT';
  }

  static String dartTypeToSQL(dynamic value) {
    if (value == null) return 'TEXT';

    switch (value.runtimeType) {
      case int:
        return 'INTEGER';
      case double:
        return 'DOUBLE PRECISION';
      case bool:
        return 'BOOLEAN';
      case DateTime:
        return 'TIMESTAMP';
      case String:
        return 'TEXT';
      default:
        return 'TEXT';
    }
  }

  static Map<String, dynamic> generateInsertQueryFromClass(String tableName, Map<String, dynamic> data) {
    // Exclude 'id' if present, as it's usually auto-generated
    final filteredEntries = data.entries.where((e) => e.key != 'id').toList();
    final columns = filteredEntries.map((e) => e.key).join(', ');
    final placeholders = List.generate(filteredEntries.length, (i) => '@$i').join(', ');
    final values = filteredEntries.map((e) => e.value).toList();

    final query = 'INSERT INTO "$tableName" ($columns) VALUES ($placeholders) RETURNING *;';
    return {'query': query, 'params': values};
  }

  static Map<String, dynamic> generateSmartUpdate({
    required String table,
    required Map<String, dynamic> oldData,
    required Map<String, dynamic> newData,
    List<String> ignoreParameters = const [],
    String primaryKey = 'uuid',
  }) {
    ignoreParameters.add('id');
    print(ignoreParameters);
    for (var k in ignoreParameters) {
      oldData.remove(k);
      newData.remove(k);
    }
    if (!oldData.containsKey(primaryKey)) {
      throw Exception('Primary key "$primaryKey" missing in oldData');
    }

    final Map<String, dynamic> updates = {};

    // Only copy changed, non-null values
    newData.forEach((key, value) {
      if (value == null) return;
      if (key == primaryKey) return;
      if (key == 'created_at') return;

      if (oldData[key] != value) {
        updates[key] = value;
      }
    });

    if (updates.isEmpty) {
      throw Exception('No fields changed');
    }

    int i = 0;
    final List<String> sets = [];
    final List<dynamic> params = [];

    updates.forEach((key, value) {
      sets.add('$key = @$i');
      params.add(value);
      i++;
    });

    // WHERE
    final whereIndex = i;
    params.add(oldData[primaryKey]);

    final query =
        '''
UPDATE "$table"
SET ${sets.join(', ')}
WHERE $primaryKey = @$whereIndex
RETURNING *;
''';

    return {'query': query, 'params': params, 'changedKeys': updates.keys.toList()};
  }

  static Map<String, dynamic> generateInsertListQueryFromClass(String tableName, List<Map<String, dynamic>> dataList) {
    if (dataList.isEmpty) {
      throw ArgumentError('dataList cannot be empty');
    }

    // Build an ordered set of columns across all rows, excluding 'id'
    final Set<String> colSet = {};
    // Preserve order from the first row first
    for (final entry in dataList.first.entries) {
      if (entry.key != 'id') colSet.add(entry.key);
    }
    // Include any additional keys from subsequent rows
    for (final row in dataList.skip(1)) {
      for (final key in row.keys) {
        if (key != 'id') colSet.add(key);
      }
    }

    final columns = colSet.toList();

    // Prepare placeholders and flat params list
    final params = <dynamic>[];
    final valueGroups = <String>[];
    var paramIndex = 0;

    for (final row in dataList) {
      final placeholders = <String>[];
      for (final col in columns) {
        placeholders.add('@$paramIndex');
        params.add(row.containsKey(col) ? row[col] : null);
        paramIndex++;
      }
      valueGroups.add('(${placeholders.join(', ')})');
    }

    final query = 'INSERT INTO "$tableName" (${columns.join(', ')}) VALUES ${valueGroups.join(', ')} RETURNING *;';

    return {'query': query, 'params': params};
  }

  static Map<String, dynamic> buildConditions(Map<String, dynamic> requestBody, {List<String>? searchKeys, bool deleted = false, int? limit, int? offset, String? prefix, bool includeDelete = true}) {
    // final conditions = <String>['deleted = $deleted'];
    var conditions = <String>[];
    if (includeDelete) {
      if (prefix == null) {
        conditions = <String>['deleted = $deleted'];
      } else {
        conditions = <String>['$prefix.deleted = $deleted'];
      }
    }
    final params = <dynamic>[];

    for (var key in requestBody.keys) {
      var value = requestBody[key];
      // Ignore pagination-related keys
      if (key == 'page_number' || key == 'page_size') {
        continue; // skip these keys from WHERE conditions
      }
      if (key == 'search' && value != null && value.toString().isNotEmpty && searchKeys != null) {
        final search = value.toString().toLowerCase();
        final searchCondition = searchKeys.map((k) => '${prefix != null ? '$prefix.' : ''}$k ILIKE @${params.length + searchKeys.indexOf(k)}').join(' OR ');
        conditions.add('($searchCondition)');
        for (int i = 0; i < searchKeys.length; i++) {
          params.add('%$search%');
        }
      } else if (value is bool) {
        if (prefix != null) {
          conditions.add('$prefix.$key = @${params.length}');
        } else {
          conditions.add('$key = @${params.length}');
        }
        params.add(value);
      } else if (value is List && value.isNotEmpty) {
        final placeholders = value.map((v) => '@${params.length + value.indexOf(v)}').join(', ');
        conditions.add('$key IN ($placeholders)');
        params.addAll(value);
      } else if (value != null && value.toString().isNotEmpty) {
        final v = value.toString();
        if (prefix != null) {
          conditions.add('LOWER($prefix.$key) = LOWER(@${params.length})');
        } else {
          conditions.add('LOWER($key) = LOWER(@${params.length})');
        }
        params.add(v);
      }
    }

    requestBody.forEach((key, value) {});

    final suffixParts = <String>[];
    final suffixParams = <dynamic>[];
    if (limit != null) {
      suffixParts.add('LIMIT @${suffixParams.length + params.length}');
      suffixParams.add(limit);
    }
    if (offset != null) {
      suffixParts.add('OFFSET @${suffixParams.length + params.length}');
      suffixParams.add(offset);
    }
    final suffix = suffixParts.join(' ');
    return {'conditions': conditions, 'params': params, 'suffix': suffix, 'suffixParams': suffixParams};
  }

  /// Returns ordered column names for a given table.
  ///
  /// Example: `await DBFunctions.getColumnNames(connection, 'recipe_details');`
  static Future<List<String>> getColumnNames(Connection connection, String tableName, {String schema = 'public'}) async {
    final res = await connection.execute(
      Sql.named('''
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = @0 AND table_name = @1
        ORDER BY ordinal_position;
      '''),
      parameters: [schema, tableName],
    );

    return res.map((row) => row[0] as String).toList();
  }

  /// Convenience: prints key/value pairs for the first row in a Result.
  /// (Column names are not reliably available from `Result` in all postgres package versions.)
  static void debugPrintFirstRow(Result res, List<String> keys) {
    return;
    if (res.isEmpty) return;
    for (int i = 0; i < keys.length && i < res.first.length; i++) {
      print('${keys[i]} | ${res.first[i]}');
    }
  }

  static mapFromResultRow(Result res, List<String> keys) {
    debugPrintFirstRow(res, keys);
    return res.map((row) => Map.fromIterables(keys, row.toList())).toList();
  }

  static String generateRandomPassword({int length = 12}) {
    const String chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#\$%^&*()_+[]{}';
    Random random = Random.secure();
    return List.generate(length, (index) => chars[random.nextInt(chars.length)]).join();
  }

  static String generateRandomOtp({int length = 6}) {
    const String chars = '0123456789';
    Random random = Random.secure();
    return '123456' ?? List.generate(length, (index) => chars[random.nextInt(chars.length)]).join();
  }

  static String? checkParamValidRequest(List<String> requestParams, List<String> requiredParams) {
    if (!requestParams.containsAllElements(requiredParams)) {
      requiredParams.removeWhere((element) => requestParams.contains(element));
      return 'Required parameters ${requiredParams.join(', ')} are missing';
    }
    return null;
  }

  static multipartImageConfigure(Request request, String directory, String fileTitle, {int startIndex = 0}) async {
    Map<String, dynamic> response = {'status': 400};

    final multipart = request.multipart();
    if (multipart == null) {
      response['message'] = 'Content-Type must be multipart/form-data';
      return Response.badRequest(body: jsonEncode(response));
    }

    const allowedExt = {'jpg', 'jpeg', 'png', 'webp'};
    const maxBytes = 5 * 1024 * 1024; // 5 MB per file

    // Ensure directory exists
    final safeDir = directory.startsWith('/') ? directory.substring(1) : directory;

    final root = Directory('${AppConfig.uploadsDir}/$safeDir');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }

    final List<String> savedPaths = [];
    int index = 0;

    await for (final part in multipart.parts) {
      final bytes = await part.readBytes();
      if (bytes.isEmpty) continue;

      if (bytes.length > maxBytes) {
        response['message'] = 'One of the files is too large. Max allowed size is 5 MB';
        return Response.badRequest(body: jsonEncode(response));
      }

      final filename = fileTitle;
      String ext = 'jpg';
      if (filename.contains('.')) {
        ext = filename.split('.').last.toLowerCase();
      }

      if (!allowedExt.contains(ext)) {
        response['message'] = 'Only image files are allowed. Supported: ${allowedExt.toList()}';
        return Response.badRequest(body: jsonEncode(response));
      }

      // 1st file → no suffix, others → _1, _2, ...
      final suffix = '_${index + startIndex}';
      final fileName = '$fileTitle$suffix.$ext';
      final filePath = '${root.path}/$fileName';

      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      final relativePath = file.path.replaceAll('\\', '/').replaceFirst(AppConfig.uploadsDir, '');
      savedPaths.add(relativePath.startsWith('/') ? relativePath : '/$relativePath');
      index++;
    }

    if (savedPaths.isEmpty) {
      response['message'] = 'No file found in form-data with key "file"';
      return Response.badRequest(body: jsonEncode(response));
    }

    return savedPaths.length == 1 ? savedPaths.first : savedPaths;
  }

  static String _sqlLiteral(dynamic v) {
    if (v == null) return 'NULL';

    if (v is bool) return v ? 'TRUE' : 'FALSE';

    if (v is num) return v.toString();

    if (v is DateTime) {
      // Postgres timestamp literal
      return "TIMESTAMP '${v.toIso8601String()}'";
    }

    if (v is List) {
      // For ANY(@i) use cases. Produces ARRAY[...]
      final items = v.map(_sqlLiteral).join(', ');
      return 'ARRAY[$items]';
    }

    // default: string-ish
    final s = v.toString().replaceAll("'", "''");
    return "'$s'";
  }

  /// Expands numeric placeholders used by Sql.named: @0, @1, @2 ...
  /// Good enough for logs.
  ///
  /// Example:
  ///   print(expandNamedSql(query, params));
  static String expandNamedSql(String query, List<dynamic> params) {
    var out = query;

    // Replace longer indices first to avoid @1 matching inside @10.
    for (int i = params.length - 1; i >= 0; i--) {
      out = out.replaceAll('@$i', _sqlLiteral(params[i]));
    }
    return out;
  }

  /// Expands numeric placeholders used by Sql.named: @0, @1, @2 ...
  /// Good enough for logs.
  ///
  /// Example:
  ///   print(expandNamedSql(query, params));
  static String expandNamedSqlMap(String query, Map<String, dynamic> params) {
    var out = query;
    params.forEach((k, v) {
      out = out.replaceAll('@$k', _sqlLiteral(params[k]));
    });

    return out;
  }

  /// Convenience logger
  static void printSqlWithParams(String query, List<dynamic> params) {
    final expanded = expandNamedSql(query, params);
    // ignore: avoid_print
    print(expanded);
  }

  static void printSqlWithParamsMap(String query, Map<String, dynamic> params) {
    final expanded = expandNamedSqlMap(query, params);
    // ignore: avoid_print
    print(expanded);
  }
}
