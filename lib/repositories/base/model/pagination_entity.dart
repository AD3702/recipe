import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class PaginationEntity {
  int totalCount;
  int pageSize;
  int pageNumber;
  int totalPages = 0;
  bool hasNextPage = false;
  bool hasPreviousPage = false;

  PaginationEntity({required this.totalCount, required this.pageSize, required this.pageNumber}) {
    hasNextPage = ((pageNumber) * (pageSize)) < totalCount;
    hasPreviousPage = (pageNumber) > 1;
    totalPages = (totalCount / pageSize).ceil();
  }

  Map<String, dynamic> get toJson {
    return {
      'total_count'.snakeToCamel: totalCount,
      'page_size'.snakeToCamel: pageSize,
      'page_number'.snakeToCamel: pageNumber,
      'total_pages'.snakeToCamel: totalPages,
      'has_next_page'.snakeToCamel: hasNextPage,
      'has_previous_page'.snakeToCamel: hasPreviousPage,
    };
  }
}
