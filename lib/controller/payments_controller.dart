import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

class PaymentsController {
  late Connection connection;

  PaymentsController._() {
    connection = BaseRepository.baseRepository.connection;
    DBFunctions.getColumnNames(connection, AppConfig.subscriptionPlans).then((value) {
      subscriptionKeys = value;
    });
    DBFunctions.getColumnNames(connection, AppConfig.userSubscriptions).then((value) {
      userSubscriptionKeys = value;
    });
  }

  List<String> subscriptionKeys = [];
  List<String> userSubscriptionKeys = [];

  static PaymentsController payments = PaymentsController._();

  Future<Response> getSubscriptionPlansList(String? userType) async {
    try {
      final String safeUserType = (userType ?? '').toString().trim().toUpperCase();
      final String finalUserType = safeUserType.isEmpty ? 'USER' : safeUserType;

      final query = Sql.named('''
      SELECT
        ${subscriptionKeys.isEmpty ? '*' : subscriptionKeys.join(',')}
      FROM ${AppConfig.subscriptionPlans}
      WHERE (deleted = false OR deleted IS NULL)
        AND active = true
        AND UPPER(COALESCE(user_type, 'USER')) = @user_type
      ORDER BY rank ASC
      ''');

      final result = await connection.execute(query, parameters: {'user_type': finalUserType});

      final keys = subscriptionKeys.isEmpty ? await DBFunctions.getColumnNames(connection, AppConfig.subscriptionPlans) : subscriptionKeys;
      final list = DBFunctions.mapFromResultRow(result, keys);

      return Response.ok(jsonEncode({'status': 200, 'count': list.length, 'data': list}), headers: {'Content-Type': 'application/json'});
    } catch (e, st) {
      print('getSubscriptionPlansList error: $e');
      print(st);

      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to fetch subscription plans'}), headers: {'Content-Type': 'application/json'});
    }
  }

  /// Create or update a user subscription (manual entry or after payment verification)
  ///
  /// Expected keys (snake_case in DB):
  /// user_id, plan_code, start_at, end_at, status, amount_paid, currency,
  /// payment_provider, provider_subscription_id, provider_payment_id
  Future<Response> upsertUserSubscription(Map<String, dynamic> requestBody) async {
    try {
      final int userId = int.tryParse((requestBody['user_id'] ?? requestBody['userId'] ?? '0').toString()) ?? 0;
      final int recipeId = int.tryParse((requestBody['recipe_id'] ?? requestBody['userId'] ?? '0').toString()) ?? 0;
      final String planCode = (requestBody['plan_code'] ?? requestBody['planCode'] ?? '').toString().toUpperCase();

      if (userId <= 0 || planCode.trim().isEmpty) {
        return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_id and plan_code are required'}), headers: {'Content-Type': 'application/json'});
      }

      final String status = (requestBody['status'] ?? 'ACTIVE').toString().toUpperCase();
      final int amountPaid = int.tryParse((requestBody['amount_paid'] ?? requestBody['amountPaid'] ?? '0').toString()) ?? 0;
      final String currency = (requestBody['currency'] ?? 'INR').toString();
      final String paymentProvider = (requestBody['payment_provider'] ?? requestBody['paymentProvider'] ?? 'RAZORPAY').toString().toUpperCase();

      final String providerSubscriptionId = (requestBody['provider_subscription_id'] ?? requestBody['providerSubscriptionId'] ?? '').toString();
      final String providerPaymentId = (requestBody['provider_payment_id'] ?? requestBody['providerPaymentId'] ?? '').toString();

      final String? providerSubId = providerSubscriptionId.trim().isEmpty ? null : providerSubscriptionId.trim();
      final String? providerPayId = providerPaymentId.trim().isEmpty ? null : providerPaymentId.trim();

      DateTime parseDateTime(dynamic dt, DateTime fallback) {
        if (dt == null) return fallback;
        if (dt is DateTime) return dt;
        try {
          return DateTime.parse(dt.toString());
        } catch (_) {
          return fallback;
        }
      }

      DateTime startAt = parseDateTime(requestBody['start_at'] ?? requestBody['startAt'], DateTime.now());
      DateTime endAt = parseDateTime(requestBody['end_at'] ?? requestBody['endAt'], startAt.add(const Duration(days: 30)));

      // Always cancel any existing ACTIVE subscription for this user before inserting the new one.
      final cancelSql = Sql.named('''
        UPDATE ${AppConfig.userSubscriptions}
        SET status = 'CANCELLED', active = false, updated_at = NOW()
        WHERE user_id = @user_id
          AND (deleted = false OR deleted IS NULL)
          AND UPPER(COALESCE(status,'')) = 'ACTIVE'
      ''');
      await connection.execute(cancelSql, parameters: {'user_id': userId});

      final String uuid = const Uuid().v8();

      final insertSql = Sql.named('''
        INSERT INTO ${AppConfig.userSubscriptions}
          (uuid, user_id, recipe_id, plan_code, start_at, end_at, status, amount_paid, currency, payment_provider, provider_subscription_id, provider_payment_id, active, deleted, created_at, updated_at)
        VALUES
          (@uuid, @user_id, @recipe_id, @plan_code, @start_at, @end_at, @status, @amount_paid, @currency, @payment_provider, @provider_subscription_id, @provider_payment_id, true, false, NOW(), NOW())
        RETURNING ${userSubscriptionKeys.isEmpty ? '*' : userSubscriptionKeys.join(',')}
      ''');

      final res = await connection.execute(
        insertSql,
        parameters: {
          'uuid': uuid,
          'user_id': userId,
          'recipe_id': recipeId,
          'plan_code': planCode,
          'start_at': startAt.toIso8601String(),
          'end_at': endAt.toIso8601String(),
          'status': status,
          'amount_paid': amountPaid,
          'currency': currency,
          'payment_provider': paymentProvider,
          'provider_subscription_id': providerSubId,
          'provider_payment_id': providerPayId,
        },
      );

      final keys = userSubscriptionKeys.isEmpty ? await DBFunctions.getColumnNames(connection, AppConfig.userSubscriptions) : userSubscriptionKeys;
      final mapped = DBFunctions.mapFromResultRow(res, keys);

      return Response.ok(jsonEncode({'status': 200, 'message': 'Subscription created', 'data': mapped.isNotEmpty ? mapped.first : {}}), headers: {'Content-Type': 'application/json'});
    } catch (e, st) {
      print('upsertUserSubscription error: $e');
      print(st);
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to upsert subscription'}), headers: {'Content-Type': 'application/json'});
    }
  }

  /// List user subscriptions
  /// Filters:
  /// - user_id (required)
  /// - status (optional: ACTIVE/EXPIRED/CANCELLED)
  Future<Response> getUserSubscriptionsList(Map<String, dynamic> requestBody) async {
    try {
      final int userId = int.tryParse((requestBody['user_id'] ?? requestBody['userId'] ?? '0').toString()) ?? 0;
      if (userId <= 0) {
        return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_id is required'}), headers: {'Content-Type': 'application/json'});
      }

      final String status = (requestBody['status'] ?? '').toString().toUpperCase().trim();
      final int limit = int.tryParse((requestBody['limit'] ?? 20).toString()) ?? 20;
      final int offset = int.tryParse((requestBody['offset'] ?? 0).toString()) ?? 0;

      final whereStatus = status.isEmpty ? '' : "AND UPPER(COALESCE(status,'')) = @status ";

      final sql = Sql.named('''
        SELECT ${userSubscriptionKeys.join(',')}
        FROM ${AppConfig.userSubscriptions}
        WHERE (deleted = false OR deleted IS NULL)
          AND user_id = @user_id
          $whereStatus
        ORDER BY id DESC
        LIMIT @limit OFFSET @offset
      ''');

      final res = await connection.execute(sql, parameters: {'user_id': userId, if (status.isNotEmpty) 'status': status, 'limit': limit, 'offset': offset});

      final mapped = DBFunctions.mapFromResultRow(res, userSubscriptionKeys);
      return Response.ok(jsonEncode({'status': 200, 'count': mapped.length, 'data': mapped}), headers: {'Content-Type': 'application/json'});
    } catch (e, st) {
      print('getUserSubscriptionsList error: $e');
      print(st);
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to fetch user subscriptions'}), headers: {'Content-Type': 'application/json'});
    }
  }

  /// Fetch current ACTIVE subscription for a user (single row)
  Future<Response> getActiveSubscription(Map<String, dynamic> requestBody) async {
    try {
      final int userId = int.tryParse((requestBody['user_id'] ?? requestBody['userId'] ?? '0').toString()) ?? 0;
      if (userId <= 0) {
        return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_id is required'}), headers: {'Content-Type': 'application/json'});
      }

      final sql = Sql.named('''
        SELECT ${userSubscriptionKeys.join(',')}
        FROM ${AppConfig.userSubscriptions}
        WHERE (deleted = false OR deleted IS NULL)
          AND user_id = @user_id
          AND UPPER(COALESCE(status,'')) = 'ACTIVE'
        ORDER BY id DESC
        LIMIT 1
      ''');

      final res = await connection.execute(sql, parameters: {'user_id': userId});
      final mapped = DBFunctions.mapFromResultRow(res, userSubscriptionKeys);

      return Response.ok(jsonEncode({'status': 200, 'data': mapped.isNotEmpty ? mapped.first : null}), headers: {'Content-Type': 'application/json'});
    } catch (e, st) {
      print('getActiveSubscription error: $e');
      print(st);
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to fetch active subscription'}), headers: {'Content-Type': 'application/json'});
    }
  }
}
