import 'package:hive/hive.dart';

/// Local settings persistence using Hive.
class SettingsLocalDataSource {
  SettingsLocalDataSource(this._box);

  static const String boxName = 'settings';
  static const String _displayNameKey = 'display_name';

  final Box<String> _box;

  /// Returns the last saved display name, if any.
  String? getDisplayName() => _box.get(_displayNameKey);

  /// Persists the display name.
  Future<void> setDisplayName(String name) => _box.put(_displayNameKey, name);
}
