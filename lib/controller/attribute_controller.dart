import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:recipe/repositories/attribute/model/attribute_entity.dart';
import 'package:recipe/repositories/base/model/pagination_entity.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:shelf/shelf.dart';

class AttributeController {
  late Connection connection;

  AttributeController._() {
    connection = BaseRepository.baseRepository.connection;
  }

  static AttributeController attribute = AttributeController._();
  final keys = AttributeEntity().toTableJson.keys.toList();

  ///GET ATTRIBUTE LIST
  ///
  ///
  ///
  Future<(List<AttributeEntity>, PaginationEntity)> getAttributeList(Map<String, dynamic> requestBody) async {
    int? pageSize = int.tryParse(requestBody['page_size'].toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    final conditionData = DBFunctions.buildConditions(
      requestBody,
      searchKeys: ['name', 'label'],
      limit: pageSize,
      offset: (pageNumber != null && pageSize != null) ? (pageNumber - 1) * pageSize : null,
    );

    final conditions = conditionData['conditions'] as List<String>;
    final suffix = conditionData['suffix'] as String;
    final params = conditionData['params'] as List<dynamic>;
    final suffixParams = conditionData['suffixParams'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.attributeDetails} WHERE ${conditions.join(' AND ')} $suffix';
    final countQuery = 'SELECT COUNT(*) FROM ${AppConfig.attributeDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params + suffixParams);
    final countRes = await connection.execute(Sql.named(countQuery), parameters: params);
    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    
    List<AttributeEntity> attributeList = [];
    for (var attribute in resList) {
      attributeList.add(AttributeEntity.fromJson(attribute));
    }
    return (attributeList, paginationEntity);
  }

  Future<Response> getAttributeListResponse(Map<String, dynamic> requestBody) async {
    var attributeList = await getAttributeList(requestBody);
    Map<String, dynamic> response = {'status': 200, 'message': 'Attribute list found successfully'};
    response['data'] = attributeList.$1.map((e) => e.toJson).toList();
    response['pagination'] = attributeList.$2.toJson;
    return Response(200, body: jsonEncode(response));
  }

  ///GET ATTRIBUTE DETAILS
  ///
  ///
  ///
  Future<Response> getAttributeFromUuidResponse(String uuid) async {
    var attributeResponse = await getAttributeFromUuid(uuid);

    if (attributeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Attribute not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      Map<String, dynamic> response = {'status': 200, 'message': 'Attribute found', 'data': attributeResponse.toJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<AttributeEntity?> getAttributeFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.attributeDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return AttributeEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<AttributeEntity?> getAttributeFromName(String name) async {
    final conditionData = DBFunctions.buildConditions({'name': name});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.attributeDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return AttributeEntity.fromJson(resList.first);
    }
    return null;
  }

  ///ADD ATTRIBUTE
  ///
  ///
  Future<Response> addAttribute(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    List<String> requiredParams = ['name'];
    List<String> requestParams = requestData.keys.toList();
    var res = DBFunctions.checkParamValidRequest(requestParams, requiredParams);
    if (res != null) {
      response['message'] = res;
      return Response.badRequest(body: jsonEncode(response));
    }
    AttributeEntity? attributeEntity = AttributeEntity.fromJson(requestData);
    AttributeEntity? attributeWithName = await getAttributeFromName(attributeEntity.name ?? '');
    if (attributeWithName != null) {
      response['message'] = 'Attribute with name already exists';
      return Response.badRequest(body: jsonEncode(response));
    }
    attributeEntity = await createNewAttribute(attributeEntity);
    response['status'] = 200;
    response['message'] = 'Attribute created successfully';
    return Response(201, body: jsonEncode(response));
  }

  ///CREATE ATTRIBUTE
  ///
  ///
  ///
  Future<AttributeEntity?> createNewAttribute(AttributeEntity attribute) async {
    var insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.attributeDetails, attribute.toTableJson);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return AttributeEntity.fromJson(resList.first);
    }
    return null;
  }

  ///CREATE ATTRIBUTE LIST
  ///
  ///
  ///
  Future<AttributeEntity?> insertNewAttributeList() async {
    List<String> attributes = [
      'Item',
      'TableSpoon',
      'Teaspoon',
      'Cup',
      'Milis',
      'Grams',
      'Kilogram',
      'Pound',
      'Ounce',
      'Fluid Ounce',
      'Litre',
      'Deciliter',
      'Centiliter',
      'Bottle',
      'Pinch',
      'Can',
      'Bunch',
      'Packet',
    ];
    List<String> attributesLabel = ['', 'Tbsp', 'Tsp', 'Cup', 'ml', 'g', 'kg', 'lb', 'oz', 'fl oz', 'L', 'dl', 'cl', 'btl', 'pinch', 'can', 'bunch', 'pkt'];
    List<AttributeEntity> attributeList = List.generate(attributes.length, (index) => AttributeEntity(name: attributes[index], label: attributesLabel[index]));
    List<String?> existingEntityList = (await getAttributeList({})).$1.map((e) => e.name).toList();
    attributeList.removeWhere((element) => existingEntityList.toList().contains(element.name));
    print(attributeList);
    if (attributeList.isNotEmpty) {
      var insertQuery = DBFunctions.generateInsertListQueryFromClass(AppConfig.attributeDetails, attributeList.map((e) => e.toTableJson).toList());
      print(insertQuery);
      final query = insertQuery['query'] as String;
      final params = insertQuery['params'] as List<dynamic>;
      final res = await connection.execute(Sql.named(query), parameters: params);
      var resList = DBFunctions.mapFromResultRow(res, keys) as List;
      if (resList.isNotEmpty) {
        return AttributeEntity.fromJson(resList.first);
      }
    }
    return null;
  }

  ///DELETE ATTRIBUTE
  ///
  ///
  ///
  Future<Response> deleteAttributeFromUuidResponse(String uuid) async {
    print(uuid);
    var attributeResponse = await getAttributeFromUuid(uuid);
    if (attributeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Attribute not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      await deleteAttributeFromUuid(uuid);
      Map<String, dynamic> response = {'status': 200, 'message': 'Attribute deleted successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deleteAttributeFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.attributeDetails} SET deleted = true, active = false WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }

  ///DEACTIVATE ATTRIBUTE
  ///
  ///
  ///
  Future<Response> deactivateAttributeFromUuidResponse(String uuid, bool active) async {
    print(uuid);
    var attributeResponse = await getAttributeFromUuid(uuid);
    if (attributeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Attribute not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      if (attributeResponse.active == active) {
        Map<String, dynamic> response = {'status': 404, 'message': 'Attribute already ${active ? 'Active' : 'De-Active'}'};
        return Response(200, body: jsonEncode(response));
      }
      await deactivateAttributeFromUuid(uuid, active);
      Map<String, dynamic> response = {'status': 200, 'message': 'Attribute status changed successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deactivateAttributeFromUuid(String uuid, bool active) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.attributeDetails} SET active = $active WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }
}
