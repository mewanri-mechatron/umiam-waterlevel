class AppException implements Exception {
  AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class GatewayException extends AppException {
  GatewayException(super.message, {super.cause});
}

class SyncException extends AppException {
  SyncException(super.message, {super.cause});
}

class ValidationException extends AppException {
  ValidationException(super.message, {super.cause});
}
