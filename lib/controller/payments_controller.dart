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

  Future<Response> getSubscriptionPlansList(int userId, String? userType, {bool isUpgrade = false}) async {
    try {
      final String safeUserType = (userType ?? '').toString().trim().toUpperCase();
      final String finalUserType = safeUserType.isEmpty ? 'USER' : safeUserType;

      // If upgrade flow requested: return only higher-rank plans with prorated adjusted price
      if (isUpgrade == true) {
        if (userId <= 0) {
          return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'userId is required for upgrade list'}), headers: {'Content-Type': 'application/json'});
        }

        // 1) Fetch current ACTIVE subscription
        final activeSql = Sql.named('''
          SELECT ${userSubscriptionKeys.isEmpty ? '*' : userSubscriptionKeys.join(',')}
          FROM ${AppConfig.userSubscriptions}
          WHERE (deleted = false OR deleted IS NULL)
            AND user_id = @user_id
            AND UPPER(COALESCE(status,'')) = 'ACTIVE'
          ORDER BY id DESC
          LIMIT 1
        ''');

        final activeRes = await connection.execute(activeSql, parameters: {'user_id': userId});
        final activeKeys = userSubscriptionKeys.isEmpty ? await DBFunctions.getColumnNames(connection, AppConfig.userSubscriptions) : userSubscriptionKeys;
        final activeList = DBFunctions.mapFromResultRow(activeRes, activeKeys);

        final now = DateTime.now().toUtc();

        // If no active subscription -> return normal plans (no credit)
        if (activeList.isEmpty) {
          final plansSql = Sql.named('''
            SELECT ${subscriptionKeys.isEmpty ? '*' : subscriptionKeys.join(',')}
            FROM ${AppConfig.subscriptionPlans}
            WHERE (deleted = false OR deleted IS NULL)
              AND active = true
              AND UPPER(COALESCE(user_type, 'USER')) = @user_type
            ORDER BY rank ASC
          ''');

          final plansRes = await connection.execute(plansSql, parameters: {'user_type': finalUserType});
          final pKeys = subscriptionKeys.isEmpty ? await DBFunctions.getColumnNames(connection, AppConfig.subscriptionPlans) : subscriptionKeys;
          final plans = DBFunctions.mapFromResultRow(plansRes, pKeys);

          final enriched = plans.map((p) {
            final int pm = int.tryParse((p['price_monthly'] ?? 0).toString()) ?? 0;
            final int py = int.tryParse((p['price_yearly'] ?? 0).toString()) ?? 0;
            return {...p, 'credit_amount': 0, 'remaining_ratio': 0, 'remaining_days': 0, 'total_days': 0, 'adjusted_price_monthly': pm, 'adjusted_price_yearly': py};
          }).toList();

          return Response.ok(
            jsonEncode({
              'status': 200,
              'message': 'No active subscription. Returning available plans.',
              'current_subscription': null,
              'credit': {'remaining_ratio': 0, 'credit_amount': 0},
              'count': enriched.length,
              'data': enriched,
            }),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final currentSub = activeList.first;
        final String currentPlanCode = (currentSub['plan_code'] ?? '').toString().trim().toUpperCase();

        DateTime parseDt(dynamic v) {
          if (v == null) return now;
          if (v is DateTime) return v.toUtc();
          try {
            return DateTime.parse(v.toString()).toUtc();
          } catch (_) {
            return now;
          }
        }

        final DateTime startAt = parseDt(currentSub['start_at']);
        final DateTime endAt = parseDt(currentSub['end_at']);

        final Duration total = endAt.difference(startAt);
        final Duration remaining = endAt.isAfter(now) ? endAt.difference(now) : Duration.zero;

        final double totalSeconds = total.inSeconds <= 0 ? 0 : total.inSeconds.toDouble();
        final double remainingSeconds = remaining.inSeconds <= 0 ? 0 : remaining.inSeconds.toDouble();
        final double remainingRatio = (totalSeconds <= 0) ? 0 : (remainingSeconds / totalSeconds);
        final double safeRatio = remainingRatio.clamp(0.0, 1.0);

        // 2) Get current plan details (rank + standard prices)
        final curPlanSql = Sql.named('''
          SELECT ${subscriptionKeys.isEmpty ? '*' : subscriptionKeys.join(',')}
          FROM ${AppConfig.subscriptionPlans}
          WHERE (deleted = false OR deleted IS NULL)
            AND active = true
            AND UPPER(COALESCE(code,'')) = @code
            AND UPPER(COALESCE(user_type,'USER')) = @user_type
          LIMIT 1
        ''');

        final curPlanRes = await connection.execute(curPlanSql, parameters: {'code': currentPlanCode, 'user_type': finalUserType});
        final sKeys = subscriptionKeys.isEmpty ? await DBFunctions.getColumnNames(connection, AppConfig.subscriptionPlans) : subscriptionKeys;
        final curPlanList = DBFunctions.mapFromResultRow(curPlanRes, sKeys);

        final int currentRank = curPlanList.isNotEmpty ? (int.tryParse((curPlanList.first['rank'] ?? 0).toString()) ?? 0) : 0;
        final int currentPriceMonthly = curPlanList.isNotEmpty ? (int.tryParse((curPlanList.first['price_monthly'] ?? 0).toString()) ?? 0) : 0;
        final int currentPriceYearly = curPlanList.isNotEmpty ? (int.tryParse((curPlanList.first['price_yearly'] ?? 0).toString()) ?? 0) : 0;

        final int totalDays = total.inDays;
        final bool isYearlyCycle = totalDays >= 300; // ~10 months+

        int paidAmount = int.tryParse((currentSub['amount_paid'] ?? 0).toString()) ?? 0;
        if (paidAmount <= 0) {
          paidAmount = isYearlyCycle ? currentPriceYearly : currentPriceMonthly;
        }

        final int creditAmount = (paidAmount * safeRatio).floor();

        // 3) Fetch upgrade plans only (rank > current)
        final upgradeSql = Sql.named('''
          SELECT ${subscriptionKeys.isEmpty ? '*' : subscriptionKeys.join(',')}
          FROM ${AppConfig.subscriptionPlans}
          WHERE (deleted = false OR deleted IS NULL)
            AND active = true
            AND UPPER(COALESCE(user_type, 'USER')) = @user_type
          ORDER BY rank ASC
        ''');

        final upgradeRes = await connection.execute(upgradeSql, parameters: {'user_type': finalUserType});
        final upgradesRaw = DBFunctions.mapFromResultRow(upgradeRes, sKeys);

        final upgrades = upgradesRaw.map((p) {
          final int pm = int.tryParse((p['price_monthly'] ?? 0).toString()) ?? 0;
          final int py = int.tryParse((p['price_yearly'] ?? 0).toString()) ?? 0;

          final int adjMonthly = (pm - creditAmount) < 0 ? 0 : (pm - creditAmount);
          final int adjYearly = (py - creditAmount) < 0 ? 0 : (py - creditAmount);

          return {
            ...p,
            'credit_amount': creditAmount,
            'remaining_ratio': safeRatio,
            'remaining_days': remaining.inDays,
            'total_days': totalDays,
            'adjusted_price_monthly': adjMonthly,
            'adjusted_price_yearly': adjYearly,
          };
        }).toList();

        return Response.ok(
          jsonEncode({
            'status': 200,
            'count': upgrades.length,
            'credit': {
              'paid_amount_used': paidAmount,
              'remaining_ratio': safeRatio,
              'credit_amount': creditAmount,
              'remaining_days': remaining.inDays,
              'total_days': totalDays,
              'current_plan': currentPlanCode,
              'cycle_type': isYearlyCycle ? 'YEARLY' : 'MONTHLY',
            },
            'data': upgrades,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

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

  /// Update subscription plan price (admin)
  ///
  /// Accepts (either snake_case or camelCase):
  /// - code (required)
  /// - user_type (optional, default USER)
  /// - price_monthly (optional)
  /// - price_yearly (optional)
  /// - currency (optional)
  /// - rank (optional)
  /// - active (optional)
  ///
  /// Example requestBody:
  /// {"code":"PLUS","user_type":"USER","price_monthly":249,"price_yearly":2499}
  Future<Response> updateSubscriptionPlanPrice(Map<String, dynamic> requestBody) async {
    try {
      final String code = (requestBody['code'] ?? requestBody['plan_code'] ?? requestBody['planCode'] ?? '').toString().trim().toUpperCase();
      final String userType = (requestBody['user_type'] ?? requestBody['userType'] ?? 'USER').toString().trim().toUpperCase();

      if (code.isEmpty) {
        return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'code is required'}), headers: {'Content-Type': 'application/json'});
      }

      final dynamic pmIn = requestBody['price_monthly'] ?? requestBody['priceMonthly'];
      final dynamic pyIn = requestBody['price_yearly'] ?? requestBody['priceYearly'];
      final dynamic currencyIn = requestBody['currency'];
      final dynamic rankIn = requestBody['rank'];
      final dynamic activeIn = requestBody['active'];

      final int? priceMonthly = pmIn == null ? null : int.tryParse(pmIn.toString());
      final int? priceYearly = pyIn == null ? null : int.tryParse(pyIn.toString());
      final String? currency = currencyIn == null ? null : currencyIn.toString().trim();
      final int? rank = rankIn == null ? null : int.tryParse(rankIn.toString());

      bool? parseBool(dynamic v) {
        if (v == null) return null;
        if (v is bool) return v;
        final s = v.toString().trim().toLowerCase();
        if (s == 'true' || s == '1' || s == 'yes') return true;
        if (s == 'false' || s == '0' || s == 'no') return false;
        return null;
      }

      final bool? active = parseBool(activeIn);

      // Build dynamic UPDATE set clause (only update provided fields)
      final List<String> sets = [];
      final Map<String, dynamic> params = {'code': code, 'user_type': userType};

      if (priceMonthly != null) {
        sets.add('price_monthly = @price_monthly');
        params['price_monthly'] = priceMonthly;
      }
      if (priceYearly != null) {
        sets.add('price_yearly = @price_yearly');
        params['price_yearly'] = priceYearly;
      }
      if (currency != null && currency.isNotEmpty) {
        sets.add('currency = @currency');
        params['currency'] = currency;
      }
      if (rank != null) {
        sets.add('rank = @rank');
        params['rank'] = rank;
      }
      if (active != null) {
        sets.add('active = @active');
        params['active'] = active;
      }

      if (sets.isEmpty) {
        return Response.badRequest(
          body: jsonEncode({'status': 400, 'message': 'Nothing to update. Provide price_monthly/price_yearly/currency/rank/active'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final sql = Sql.named('''
        UPDATE ${AppConfig.subscriptionPlans}
        SET ${sets.join(', ')}, updated_at = NOW()
        WHERE (deleted = false OR deleted IS NULL)
          AND UPPER(COALESCE(code,'')) = @code
          AND UPPER(COALESCE(user_type,'USER')) = @user_type
        RETURNING ${subscriptionKeys.isEmpty ? '*' : subscriptionKeys.join(',')}
      ''');

      final res = await connection.execute(sql, parameters: params);

      final keys = subscriptionKeys.isEmpty ? await DBFunctions.getColumnNames(connection, AppConfig.subscriptionPlans) : subscriptionKeys;
      final mapped = DBFunctions.mapFromResultRow(res, keys);

      if (mapped.isEmpty) {
        return Response.notFound(jsonEncode({'status': 404, 'message': 'Plan not found for given code/user_type'}), headers: {'Content-Type': 'application/json'});
      }

      return Response.ok(jsonEncode({'status': 200, 'message': 'Plan updated', 'data': mapped.first}), headers: {'Content-Type': 'application/json'});
    } catch (e, st) {
      print('updateSubscriptionPlanPrice error: $e');
      print(st);
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to update subscription plan'}), headers: {'Content-Type': 'application/json'});
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

      if (providerSubId != null) {
        // Always cancel any existing ACTIVE subscription for this user before inserting the new one.
        final cancelSql = Sql.named('''
        UPDATE ${AppConfig.userSubscriptions}
        SET status = 'CANCELLED', active = false, updated_at = NOW()
        WHERE user_id = @user_id
          AND (deleted = false OR deleted IS NULL)
          AND UPPER(COALESCE(status,'')) = 'ACTIVE'
      ''');
        await connection.execute(cancelSql, parameters: {'user_id': userId});
      }

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
  Future<Response> getUserSubscriptionsList(int userId) async {
    try {
      if (userId <= 0) {
        return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_id is required'}), headers: {'Content-Type': 'application/json'});
      }
      final sql = Sql.named('''
        SELECT ${userSubscriptionKeys.join(',')}
        FROM ${AppConfig.userSubscriptions}
        WHERE (deleted = false OR deleted IS NULL)
          AND user_id = @user_id
          ORDER BY updated_at DESC
      ''');

      final res = await connection.execute(sql, parameters: {'user_id': userId});

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

  /// CREATE SUBSCRIPTION PLANS (seed)
  ///
  /// Inserts default subscription plans (USER + COOK) if they don't already exist.
  /// Safe to run multiple times.
  Future<void> createSubscriptions() async {
    try {
      final List<Map<String, dynamic>> defaultPlans = [
        {'code': 'PLUS', 'name': 'Plus', 'price_monthly': 199, 'price_yearly': 1999, 'currency': '₹', 'rank': 1, 'user_type': 'USER'},
        {'code': 'PRO', 'name': 'Pro', 'price_monthly': 399, 'price_yearly': 3999, 'currency': '₹', 'rank': 2, 'user_type': 'USER'},
        {'code': 'ULTRA', 'name': 'Ultra', 'price_monthly': 699, 'price_yearly': 6999, 'currency': '₹', 'rank': 3, 'user_type': 'USER'},
        {'code': 'COOK_PLUS', 'name': 'Cook Plus', 'price_monthly': 299, 'price_yearly': 2999, 'currency': '₹', 'rank': 1, 'user_type': 'COOK'},
        {'code': 'COOK_PRO', 'name': 'Cook Pro', 'price_monthly': 599, 'price_yearly': 5999, 'currency': '₹', 'rank': 2, 'user_type': 'COOK'},
        {'code': 'COOK_ULTRA', 'name': 'Cook Ultra', 'price_monthly': 999, 'price_yearly': 9999, 'currency': '₹', 'rank': 3, 'user_type': 'COOK'},
      ];

      // Fetch existing plans (by code + user_type)
      final existingSql = Sql.named('''
        SELECT UPPER(COALESCE(code,'')) AS code, UPPER(COALESCE(user_type,'USER')) AS user_type
        FROM ${AppConfig.subscriptionPlans}
        WHERE (deleted = false OR deleted IS NULL)
      ''');

      final existingRes = await connection.execute(existingSql);
      final existingRows = DBFunctions.mapFromResultRow(existingRes, ['code', 'user_type']) as List;

      final Set<String> existingKeySet = existingRows
          .map((e) => '${(e['code'] ?? '').toString().trim().toUpperCase()}__${(e['user_type'] ?? 'USER').toString().trim().toUpperCase()}')
          .where((k) => k.trim().isNotEmpty)
          .toSet();

      final plansToInsert = defaultPlans.where((p) {
        final code = (p['code'] ?? '').toString().trim().toUpperCase();
        final userType = (p['user_type'] ?? 'USER').toString().trim().toUpperCase();
        return !existingKeySet.contains('${code}__$userType');
      }).toList();

      if (plansToInsert.isEmpty) return;

      // Build multi-row INSERT with named params
      final String table = AppConfig.subscriptionPlans;
      final StringBuffer valuesBuf = StringBuffer();
      final Map<String, dynamic> params = {};

      for (int i = 0; i < plansToInsert.length; i++) {
        final p = plansToInsert[i];
        final uuid = const Uuid().v8();

        params['uuid$i'] = uuid;
        params['code$i'] = (p['code'] ?? '').toString().trim().toUpperCase();
        params['name$i'] = (p['name'] ?? '').toString().trim();
        params['price_monthly$i'] = int.tryParse((p['price_monthly'] ?? 0).toString()) ?? 0;
        params['price_yearly$i'] = int.tryParse((p['price_yearly'] ?? 0).toString()) ?? 0;
        params['currency$i'] = (p['currency'] ?? '₹').toString();
        params['rank$i'] = int.tryParse((p['rank'] ?? 0).toString()) ?? 0;
        params['user_type$i'] = (p['user_type'] ?? 'USER').toString().trim().toUpperCase();

        valuesBuf.write('(');
        valuesBuf.write('@uuid$i, @code$i, @name$i, @price_monthly$i, @price_yearly$i, @currency$i, @rank$i, @user_type$i, true, false, NOW(), NOW()');
        valuesBuf.write(')');
        if (i != plansToInsert.length - 1) valuesBuf.write(',');
      }

      final insertSql = Sql.named('''
        INSERT INTO $table
          (uuid, code, name, price_monthly, price_yearly, currency, rank, user_type, active, deleted, created_at, updated_at)
        VALUES
          ${valuesBuf.toString()}
      ''');

      await connection.execute(insertSql, parameters: params);
    } catch (e, st) {
      print('createSubscriptions error: $e');
      print(st);
    }
  }
}
