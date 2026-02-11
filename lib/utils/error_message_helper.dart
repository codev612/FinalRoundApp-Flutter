/// Utility class to convert raw error messages to user-friendly messages
class ErrorMessageHelper {
  /// Converts a raw exception/error to a user-friendly message
  static String toUserFriendly(dynamic error) {
    if (error == null) {
      return 'An unexpected error occurred';
    }

    final errorString = error.toString().toLowerCase();

    // Network/Connection errors
    if (errorString.contains('failed host lookup') ||
        errorString.contains('no such host') ||
        errorString.contains('errno = 11001') ||
        errorString.contains('socketexception')) {
      return 'Unable to connect to server. Please check your internet connection.';
    }

    if (errorString.contains('connection refused') ||
        errorString.contains('connection timed out') ||
        errorString.contains('connection reset')) {
      return 'Cannot reach the server. Please try again later.';
    }

    if (errorString.contains('network') && errorString.contains('error')) {
      return 'Network error. Please check your internet connection and try again.';
    }

    // HTTP errors
    if (errorString.contains('401') || errorString.contains('unauthorized')) {
      return 'Your session has expired. Please sign in again.';
    }

    if (errorString.contains('403') || errorString.contains('forbidden')) {
      return 'You don\'t have permission to perform this action.';
    }

    if (errorString.contains('404') || errorString.contains('not found')) {
      return 'The requested resource was not found.';
    }

    if (errorString.contains('500') || errorString.contains('internal server error')) {
      return 'Server error. Please try again later.';
    }

    if (errorString.contains('502') || errorString.contains('bad gateway')) {
      return 'Server temporarily unavailable. Please try again later.';
    }

    if (errorString.contains('503') || errorString.contains('service unavailable')) {
      return 'Service temporarily unavailable. Please try again later.';
    }

    // ClientException (HTTP client errors)
    if (errorString.contains('clientexception')) {
      if (errorString.contains('host lookup') || errorString.contains('socket')) {
        return 'Cannot connect to server. Please check your internet connection.';
      }
      return 'Failed to communicate with server. Please try again.';
    }

    // Specific error messages that are already user-friendly
    if (errorString.contains('session not found')) {
      return 'Session not found.';
    }

    if (errorString.contains('invalid session')) {
      return 'Invalid session.';
    }

    if (errorString.contains('no transcript')) {
      return 'No transcript available.';
    }

    if (errorString.contains('microphone permission')) {
      return 'Microphone permission is required. Please enable it in settings.';
    }

    // If it's already a user-friendly message (doesn't contain technical terms)
    if (!errorString.contains('exception') &&
        !errorString.contains('error:') &&
        !errorString.contains('failed:') &&
        !errorString.contains('errno') &&
        !errorString.contains('socket') &&
        !errorString.contains('clientexception') &&
        !errorString.contains('http')) {
      // Check if it's a short, readable message
      final cleanError = error.toString();
      if (cleanError.length < 100 && !cleanError.contains(':')) {
        return cleanError;
      }
    }

    // Default fallback for unknown errors
    return 'An error occurred. Please try again.';
  }

  /// Checks if an error is a network/connection error
  static bool isNetworkError(dynamic error) {
    if (error == null) return false;
    final errorString = error.toString().toLowerCase();
    return errorString.contains('failed host lookup') ||
        errorString.contains('connection') ||
        errorString.contains('socket') ||
        errorString.contains('network') ||
        errorString.contains('timeout') ||
        errorString.contains('cannot connect') ||
        errorString.contains('unable to connect') ||
        errorString.contains('cannot reach') ||
        errorString.contains('server');
  }

  /// Checks if an error message string indicates a server/network error
  static bool isServerConnectionError(String errorMessage) {
    if (errorMessage.isEmpty) return false;
    final errorString = errorMessage.toLowerCase();
    return errorString.contains('unable to connect') ||
        errorString.contains('cannot connect') ||
        errorString.contains('cannot reach') ||
        errorString.contains('server') ||
        errorString.contains('connection') ||
        errorString.contains('network');
  }

  /// Checks if an error is an authentication error
  static bool isAuthError(dynamic error) {
    if (error == null) return false;
    final errorString = error.toString().toLowerCase();
    return errorString.contains('401') ||
        errorString.contains('unauthorized') ||
        errorString.contains('token') ||
        errorString.contains('authentication');
  }
}
