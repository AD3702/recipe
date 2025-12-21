import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class PaginationEntity {
  int totalCount;
  int pageSize;
  int pageNumber;
  bool hasNextPage = false;
  bool hasPreviousPage = false;

  PaginationEntity({required this.totalCount, required this.pageSize, required this.pageNumber}) {
    hasNextPage = ((pageNumber) * (pageSize)) < totalCount;
    hasPreviousPage = (pageNumber) > 1;
  }

  Map<String, dynamic> get toJson {
    return {
      'total_count'.snakeToCamel: totalCount,
      'page_size'.snakeToCamel: pageSize,
      'page_number'.snakeToCamel: pageNumber,
      'has_next_page'.snakeToCamel: hasNextPage,
      'has_previous_page'.snakeToCamel: hasPreviousPage,
    };
  }
}
