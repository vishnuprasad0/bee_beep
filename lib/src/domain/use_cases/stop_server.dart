import '../repositories/connection_repository.dart';

class StopServer {
  const StopServer(this._repo);

  final ConnectionRepository _repo;

  Future<void> call() => _repo.stopServer();
}
