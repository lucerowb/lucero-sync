import 'package:photo_manager/photo_manager.dart';

/// Pages through the device photo library (Camera Roll on iOS, MediaStore on
/// Android) oldest-first. Only cheap metadata is touched here — no file I/O —
/// so scanning 50k assets takes seconds.
class LibraryScanner {
  static const pageSize = 500;

  Future<bool> requestPermission() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess; // also true for iOS "Limited" access
  }

  Future<int> count() async {
    final all = await _allAssetsPath();
    return all == null ? 0 : await all.assetCountAsync;
  }

  Stream<List<AssetEntity>> pages() async* {
    final all = await _allAssetsPath();
    if (all == null) return;
    final total = await all.assetCountAsync;
    for (var page = 0; page * pageSize < total; page++) {
      yield await all.getAssetListPaged(page: page, size: pageSize);
    }
  }

  Future<AssetPathEntity?> _allAssetsPath() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // photos + videos
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: true)],
      ),
    );
    return paths.isEmpty ? null : paths.first;
  }
}
