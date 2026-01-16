import '../repositories/connection_repository.dart';

class WatchLogs {
  const WatchLogs(this._repo);

  final ConnectionRepository _repo;

  Stream<String> call() => _repo.watchLogs();
}
