import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:recipe/repositories/base/model/pagination_entity.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/category/model/category_entity.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:shelf/shelf.dart';

class CategoryController {
  late Connection connection;

  CategoryController._() {
    connection = BaseRepository.baseRepository.connection;
  }

  static CategoryController category = CategoryController._();
  final keys = CategoryEntity().toTableJson.keys.toList();

  ///GET CATEGORY LIST
  ///
  ///
  ///
  Future<(List<CategoryEntity>, PaginationEntity)> getCategoryList(Map<String, dynamic> requestBody) async {
    int? pageSize = int.tryParse(requestBody['page_size'].toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    final conditionData = DBFunctions.buildConditions(requestBody, searchKeys: ['name'], limit: pageSize, offset: (pageNumber != null && pageSize != null) ? (pageNumber - 1) * pageSize : null);

    final conditions = conditionData['conditions'] as List<String>;
    final suffix = conditionData['suffix'] as String;
    final params = conditionData['params'] as List<dynamic>;
    final suffixParams = conditionData['suffixParams'] as List<dynamic>;
    final countQuery = 'SELECT COUNT(*) FROM ${AppConfig.categoryDetails} WHERE ${conditions.join(' AND ')}';
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.categoryDetails} WHERE ${conditions.join(' AND ')} $suffix';
    final res = await connection.execute(Sql.named(query), parameters: params + suffixParams);
    final countRes = await connection.execute(Sql.named(countQuery), parameters: params);
    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;

    List<CategoryEntity> categoryList = [];
    for (var category in resList) {
      categoryList.add(CategoryEntity.fromJson(category));
    }
    return (categoryList, paginationEntity);
  }

  Future<Response> getCategoryListResponse(Map<String, dynamic> requestBody) async {
    var categoryList = await getCategoryList(requestBody);
    Map<String, dynamic> response = {'status': 200, 'message': 'Category list found successfully'};
    response['data'] = categoryList.$1.map((e) => e.toJson).toList();
    response['pagination'] = categoryList.$2.toJson;
    return Response(200, body: jsonEncode(response));
  }

  ///GET CATEGORY DETAILS
  ///
  ///
  ///
  Future<Response> getCategoryFromUuidResponse(String uuid) async {
    var categoryResponse = await getCategoryFromUuid(uuid);

    if (categoryResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Category not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      Map<String, dynamic> response = {'status': 200, 'message': 'Category found', 'data': categoryResponse.toJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<CategoryEntity?> getCategoryFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.categoryDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return CategoryEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<List<String>> getCategoryNameListFromUuidList(List<String> uuidList) async {
    if (uuidList.isEmpty) return [];

    // Build conditions for uuid IN (...)
    final conditionData = DBFunctions.buildConditions({'uuid': uuidList});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query =
        'SELECT name FROM ${AppConfig.categoryDetails} '
        'WHERE ${conditions.join(' AND ')}';

    final res = await connection.execute(Sql.named(query), parameters: params);
    final resList = DBFunctions.mapFromResultRow(res, ['name']) as List;

    final List<String> categoryList = [];
    for (final row in resList) {
      categoryList.add(row['name']);
    }
    return categoryList;
  }

  Future<CategoryEntity?> getCategoryFromName(String name) async {
    final conditionData = DBFunctions.buildConditions({'name': name});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.categoryDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return CategoryEntity.fromJson(resList.first);
    }
    return null;
  }

  ///ADD CATEGORY
  ///
  ///
  Future<Response> addCategory(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    List<String> requiredParams = ['name'];
    List<String> requestParams = requestData.keys.toList();
    var res = DBFunctions.checkParamValidRequest(requestParams, requiredParams);
    if (res != null) {
      response['message'] = res;
      return Response.badRequest(body: jsonEncode(response));
    }
    CategoryEntity? categoryEntity = CategoryEntity.fromJson(requestData);
    CategoryEntity? categoryWithName = await getCategoryFromName(categoryEntity.name ?? '');
    if (categoryWithName != null) {
      response['message'] = 'Category with name already exists';
      return Response.badRequest(body: jsonEncode(response));
    }
    categoryEntity = await createNewCategory(categoryEntity);
    response['status'] = 200;
    response['message'] = 'Category created successfully';
    return Response(201, body: jsonEncode(response));
  }

  ///CREATE CATEGORY
  ///
  ///
  ///
  Future<CategoryEntity?> createNewCategory(CategoryEntity category) async {
    var insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.categoryDetails, category.toTableJson);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return CategoryEntity.fromJson(resList.first);
    }
    return null;
  }

  ///DELETE CATEGORY
  ///
  ///
  ///
  Future<Response> deleteCategoryFromUuidResponse(String uuid) async {
    var categoryResponse = await getCategoryFromUuid(uuid);
    if (categoryResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Category not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      await deleteCategoryFromUuid(uuid);
      Map<String, dynamic> response = {'status': 200, 'message': 'Category deleted successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deleteCategoryFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.categoryDetails} SET deleted = true, active = false WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }

  ///DEACTIVATE CATEGORY
  ///
  ///
  ///
  Future<Response> deactivateCategoryFromUuidResponse(String uuid, bool active) async {
    var categoryResponse = await getCategoryFromUuid(uuid);
    if (categoryResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Category not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      if (categoryResponse.active == active) {
        Map<String, dynamic> response = {'status': 404, 'message': 'Category already ${active ? 'Active' : 'De-Active'}'};
        return Response(200, body: jsonEncode(response));
      }
      await deactivateCategoryFromUuid(uuid, active);
      Map<String, dynamic> response = {'status': 200, 'message': 'Category status changed successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deactivateCategoryFromUuid(String uuid, bool active) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.categoryDetails} SET active = $active WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }

  ///CREATE CATEGORY LIST (seed)
  ///
  /// Inserts a default set of common recipe categories if they don't already exist.
  /// Returns the first inserted CategoryEntity (or null if nothing inserted).
  Future<CategoryEntity?> insertNewCategoryList() async {
    // Common recipe categories (broad + practical)
    final List<String> categories = [
      'Appetizers',
      'Breakfast',
      'Brunch',
      'Lunch',
      'Dinner',
      'Snacks',
      'Side Dishes',
      'Soups',
      'Salads',
      'Sandwiches & Wraps',
      'Pasta',
      'Rice & Grains',
      'Noodles',
      'Pizza',
      'Burgers',
      'Tacos & Burritos',
      'Curries',
      'Stir-Fries',
      'Casseroles',
      'BBQ & Grilling',
      'Seafood',
      'Chicken',
      'Mutton & Lamb',
      'Beef',
      'Pork',
      'Vegetarian',
      'Vegan',
      'Gluten-Free',
      'Keto',
      'Low Carb',
      'High Protein',
      'Healthy',
      'Comfort Food',
      'Quick & Easy',
      'One Pot Meals',
      'Meal Prep',
      'Kids Friendly',
      'Party Food',
      'Baking',
      'Breads',
      'Cakes',
      'Cookies',
      'Desserts',
      'Ice Cream & Frozen Desserts',
      'Chocolate',
      'Puddings & Custards',
      'Indian',
      'Gujarati',
      'Punjabi',
      'South Indian',
      'Chinese',
      'Italian',
      'Mexican',
      'Thai',
      'Japanese',
      'Korean',
      'Mediterranean',
      'Middle Eastern',
      'American',
      'European',
      'African',
      'Beverages',
      'Smoothies',
      'Juices',
      'Coffee & Tea',
      'Mocktails',
      'Sauces & Dips',
      'Chutneys',
      'Pickles',
      'Marinades',
      'Dry Rubs',
      'Seasonings',
      'Herbs & Spices',
      'Fermented Foods',
      'Probiotic Foods',
      'Street Food',
      'Fast Food',
      'Street Snacks',
      'Chaat',
      'Rolls & Frankies',
      'Samosas & Kachori',
      'Dosas & Idli',
      'Paratha & Roti',
      'Curries & Gravies',
      'Dal & Lentils',
      'Paneer Dishes',
      'Tofu Dishes',
      'Mushroom Dishes',
      'Egg Dishes',
      'Breakfast Bowls',
      'Smoothie Bowls',
      'Granola & Oats',
      'Salads & Bowls',
      'Wraps & Rolls',
      'Flatbreads',
      'Rice Bowls',
      'Fried Rice',
      'Biryani',
      'Pulao',
      'Khichdi',
      'Risotto',
      'Paella',
      'Ramen',
      'Pho',
      'Udon',
      'Sushi',
      'Dim Sum',
      'Dumplings',
      'Spring Rolls',
      'Wok Recipes',
      'Grilled Dishes',
      'Roasted Dishes',
      'Steamed Dishes',
      'Slow Cooker',
      'Air Fryer',
      'Instant Pot',
      'No-Cook',
      'Raw Foods',
      'Detox',
      'Weight Loss',
      'Muscle Gain',
      'Diabetic Friendly',
      'Low Sodium',
      'Heart Healthy',
      'Festival Special',
      'Navratri Special',
      'Diwali Special',
      'Christmas Special',
      'Ramadan Special',
      'Eid Special',
      'Vegan Desserts',
      'Sugar-Free Desserts',
      'Gluten-Free Desserts',
      'Ice Lollies',
      'Milkshakes',
      'Falooda',
      'Indian Sweets',
      'Halwa',
      'Barfi',
      'Ladoo',
      'Rasgulla',
      'Gulab Jamun',
      'Kheer',
      'Shrikhand',
      'Yogurt & Curd',
      'Cheese Dishes',
      'Butter & Ghee',
      'Oils & Fats',
      'Vinegar & Dressings',
      'Mayonnaise',
      'Ketchup',
      'Mustard',
      'Hot Sauce',
      'Salsa',
      'Relish',
      'Purees',
      'Stocks & Broths',
      'Baby Food',
      'Toddler Meals',
      'Senior Friendly',
      'Picnic Food',
      'Travel Food',
      'Tiffin Recipes',
      'Office Lunch',
      'Budget Meals',
      'Luxury Dishes',
      'Chef Specials',
      'Fusion Cuisine',
      'Experimental Recipes',
      'Traditional Recipes',
      'Home Style',
      'Restaurant Style',
      'Cloud Kitchen',
      'Catering Recipes',
      'Bulk Cooking',
      'Wedding Specials',
      'Birthday Specials',
      'Anniversary Specials',
      'Bridal Shower',
      'Baby Shower',
      'Potluck',
      'Buffet Style',
      'Plated Dishes',
      'Tasting Menu',
      'Fine Dining',
      'Spice Mixes',
      'Basics',
    ];

    // Fetch existing category names
    List<String> existingEntityList = [];
    var query = 'SELECT ${keys.join(',')} FROM ${AppConfig.categoryDetails}';
    var res = await connection.execute(Sql.named(query));
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;

    for (var category in resList) {
      existingEntityList.add(category['name']);
    }

    // Create entities and remove existing
    final List<CategoryEntity> categoryList = categories.map((name) => CategoryEntity(name: name)).where((e) => !existingEntityList.contains((e.name ?? '').trim())).toList();

    if (categoryList.isEmpty) return null;

    final insertQuery = DBFunctions.generateInsertListQueryFromClass(AppConfig.categoryDetails, categoryList.map((e) => e.toTableJson).toList());

    query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;

    res = await connection.execute(Sql.named(query), parameters: params);
    resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return CategoryEntity.fromJson(resList.first);
    }
    return null;
  }
}
