import 'package:photo_manager/photo_manager.dart';

/// Pages through the system photo library (Photos on iOS/macOS, MediaStore on
/// Android) oldest-first. Only cheap metadata is touched here, no file I/O, so
/// scanning tens of thousands of assets takes seconds.
class LibraryScanner {
  static const pageSize = 500;

  Future<bool> requestPermission() async => (await PhotoManager.requestPermissionExtend()).hasAccess;

  Stream<List<AssetEntity>> pages({required bool includeVideos}) async* {
    final paths = await PhotoManager.getAssetPathList(
      type: includeVideos ? RequestType.common : RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: true)]),
    );
    if (paths.isEmpty) return;
    final all = paths.first;
    final total = await all.assetCountAsync;
    for (var page = 0; page * pageSize < total; page++) {
      yield await all.getAssetListPaged(page: page, size: pageSize);
    }
  }
}
