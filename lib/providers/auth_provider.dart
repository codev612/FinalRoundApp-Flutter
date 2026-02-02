import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import '../config/app_config.dart';

class AuthProvider extends ChangeNotifier {
  String? _token;
  String? _userEmail;
  String? _userName;
  bool? _emailVerified;
  bool _isLoading = false;
  String? _errorMessage;
  Timer? _sessionWatchdog;
  bool _watchdogInFlight = false;
  final math.Random _jitter = math.Random();
  String? _pendingLoginChallengeId;
  bool get requiresSecurityCheck => _pendingLoginChallengeId != null && _pendingLoginChallengeId!.isNotEmpty;
  String? get pendingLoginChallengeId => _pendingLoginChallengeId;

  String? get token => _token;
  String? get userEmail => _userEmail;
  String? get userName => _userName;
  bool? get emailVerified => _emailVerified;
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? _lastVerificationCode;
  String? get lastVerificationCode => _lastVerificationCode;

  AuthProvider() {
    _loadToken();
  }

  @override
  void dispose() {
    _stopSessionWatchdog();
    super.dispose();
  }

  Future<void> _loadToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString('auth_token');
      _userEmail = prefs.getString('user_email');
      if (_token != null && _token!.isNotEmpty) {
        // Verify token is still valid by checking with server. If server is temporarily
        // unreachable, keep the token and re-check later (watchdog).
        final status = await _checkToken();
        if (status == _TokenCheck.invalid) {
          await _clearAuth();
        } else if (status == _TokenCheck.valid) {
          _startSessionWatchdog();
        } else {
          // unknown (e.g. offline): keep token and watch for revoke later
          _startSessionWatchdog();
        }
      }
      notifyListeners();
    } catch (e) {
      print('Error loading auth token: $e');
    }
  }

  Future<_TokenCheck> _checkToken() async {
    if (_token == null) return _TokenCheck.invalid;
    
    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/me');
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final user = data['user'];
        if (user != null) {
          _userEmail = user['email'] as String?;
          _userName = user['name'] as String?;
          _emailVerified = user['email_verified'] as bool?;
        }
        return _TokenCheck.valid;
      }

      // Invalid/expired token or revoked session should force sign-out.
      if (response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 404) {
        return _TokenCheck.invalid;
      }

      // Other server errors: don't sign out; try again later.
      return _TokenCheck.unknown;
    } catch (e) {
      // If server is not available, keep token and retry later.
      final msg = e.toString();
      if (msg.contains('Connection') || msg.contains('refused') || msg.contains('Failed host lookup')) {
        return _TokenCheck.unknown;
      }
      // Other errors: don't force logout.
      print('Token verification error: $e');
      return _TokenCheck.unknown;
    }
  }

  void _startSessionWatchdog() {
    _stopSessionWatchdog();
    if (!isAuthenticated) return;
    // Low-frequency watchdog with jitter to avoid thundering herd.
    void scheduleNext() {
      _sessionWatchdog?.cancel();
      if (!isAuthenticated) return;
      final baseSeconds = 60;
      final jitterSeconds = _jitter.nextInt(16); // 0..15s
      _sessionWatchdog = Timer(Duration(seconds: baseSeconds + jitterSeconds), () async {
        if (_watchdogInFlight || !isAuthenticated) {
          scheduleNext();
          return;
        }
        _watchdogInFlight = true;
        try {
          final status = await _checkToken();
          if (status == _TokenCheck.invalid) {
            await _clearAuth();
            notifyListeners();
            return;
          }
        } finally {
          _watchdogInFlight = false;
        }
        scheduleNext();
      });
    }

    scheduleNext();
  }

  void _stopSessionWatchdog() {
    try {
      _sessionWatchdog?.cancel();
    } catch (_) {}
    _sessionWatchdog = null;
    _watchdogInFlight = false;
  }

  Future<bool> signIn(String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/signin');
      final clientType = kIsWeb
          ? 'web'
          : (Platform.isAndroid || Platform.isIOS ? 'mobile' : 'desktop');
      final platform = kIsWeb
          ? 'unknown'
          : (Platform.isWindows
              ? 'windows'
              : (Platform.isMacOS
                  ? 'mac'
                  : (Platform.isLinux
                      ? 'linux'
                      : (Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'unknown')))));
      // Stable device id for login security checks
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString('device_id');
      if (deviceId == null || deviceId.trim().isEmpty) {
        final rand = _jitter.nextInt(1 << 30);
        deviceId = 'device_${DateTime.now().microsecondsSinceEpoch}_$rand';
        await prefs.setString('device_id', deviceId);
      }
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'clientType': clientType,
          'platform': platform,
          'deviceId': deviceId,
        }),
      ).timeout(const Duration(seconds: 10));

      print('[AuthProvider] Sign in response status: ${response.statusCode}');
      final responseBody = response.body;
      print('[AuthProvider] Sign in response body: $responseBody');
      
      final data = jsonDecode(responseBody) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        if (data['token'] == null) {
          print('[AuthProvider] ERROR: Token missing in successful response');
          _errorMessage = 'Sign in response missing token';
          _isLoading = false;
          notifyListeners();
          return false;
        }
        
        _token = data['token'] as String;
        final user = data['user'] as Map<String, dynamic>?;
        _userEmail = user?['email'] as String? ?? email;
        _userName = user?['name'] as String?;
        _emailVerified = user?['email_verified'] as bool?;
        
        print('[AuthProvider] Token received: ${_token?.substring(0, 20)}...');
        print('[AuthProvider] User email: $_userEmail, verified: $_emailVerified');
        
        // Save to persistent storage
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('auth_token', _token!);
          if (_userEmail != null) {
            await prefs.setString('user_email', _userEmail!);
          }
          print('[AuthProvider] Token saved to SharedPreferences');
        } catch (e) {
          print('[AuthProvider] ERROR saving token: $e');
        }
        
        _errorMessage = null;
        _isLoading = false;
        print('[AuthProvider] Sign in successful, isAuthenticated will be: ${_token != null && _token!.isNotEmpty}');
        _startSessionWatchdog();
        notifyListeners();
        return true;
      } else {
        // Handle different error status codes
        String errorMsg = 'Sign in failed';
        if (response.statusCode == 403) {
          final requires = data['requiresSecurityCheck'] == true;
          if (requires) {
            _pendingLoginChallengeId = (data['challengeId'] as String?) ?? '';
            errorMsg = data['message'] as String? ?? 'Security check required. Check your email for the code.';
          } else {
            errorMsg = data['error'] as String? ??
                      data['message'] as String? ??
                      'Email not verified. Please check your inbox for the verification code.';
          }
        } else if (response.statusCode == 401) {
          errorMsg = data['error'] as String? ?? 
                    data['message'] as String? ?? 
                    'Invalid email or password';
        } else {
          errorMsg = data['error'] as String? ?? 
                    data['message'] as String? ?? 
                    'Sign in failed';
        }
        _errorMessage = errorMsg;
        _isLoading = false;
        print('[AuthProvider] Sign in failed: $_errorMessage (status: ${response.statusCode})');
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> verifyLoginChallenge(String code) async {
    final id = _pendingLoginChallengeId;
    if (id == null || id.trim().isEmpty) {
      _errorMessage = 'No pending security check';
      notifyListeners();
      return false;
    }
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/verify-login-challenge');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'challengeId': id, 'code': code.trim()}),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        _pendingLoginChallengeId = null;
        _token = data['token'] as String?;
        final user = data['user'] as Map<String, dynamic>?;
        _userEmail = user?['email'] as String?;
        _userName = user?['name'] as String?;
        _emailVerified = user?['email_verified'] as bool?;

        final prefs = await SharedPreferences.getInstance();
        if (_token != null && _token!.isNotEmpty) {
          await prefs.setString('auth_token', _token!);
        }
        if (_userEmail != null && _userEmail!.isNotEmpty) {
          await prefs.setString('user_email', _userEmail!);
        }
        _isLoading = false;
        _startSessionWatchdog();
        notifyListeners();
        return true;
      } else {
        _errorMessage = data['error'] as String? ?? 'Verification failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> signUp(String email, String name, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/signup');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'name': name,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 201) {
        _userEmail = email; // Store email for verification
        // Store verification code if returned (for development when Mailgun not configured)
        _lastVerificationCode = data['verification_code'] as String?;
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = data['error'] as String? ?? 'Sign up failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> verifyEmail(String email, String code) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/verify-email');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'code': code,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = data['error'] as String? ?? 'Verification failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> resendVerificationCode(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/resend-verification');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to resend code';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    await _clearAuth();
    notifyListeners();
  }

  Future<void> _clearAuth() async {
    _stopSessionWatchdog();
    _pendingLoginChallengeId = null;
    _token = null;
    _userEmail = null;
    _userName = null;
    _emailVerified = null;
    _errorMessage = null;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_email');
  }

  Future<void> refreshUserInfo() async {
    if (_token == null) return;
    
    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/me');
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final user = data['user'];
        if (user != null) {
          _userEmail = user['email'] as String?;
          _userName = user['name'] as String?;
          _emailVerified = user['email_verified'] as bool?;
          notifyListeners();
        }
      }
    } catch (e) {
      print('Error refreshing user info: $e');
    }
  }

  Future<String?> updateProfile({String? name, String? email}) async {
    if (_token == null) return 'Not authenticated';
    
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/profile');
      final response = await http.put(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          if (name != null) 'name': name,
          if (email != null) 'email': email,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final user = data['user'];
        final pendingEmail = data['pendingEmail'] as String?;
        
        if (user != null) {
          _userEmail = user['email'] as String?;
          _userName = user['name'] as String?;
          _emailVerified = user['email_verified'] as bool?;
          
          // Update stored email if changed (but not if pending)
          if (email != null && _userEmail != null && pendingEmail == null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('user_email', _userEmail!);
          }
        }
        
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        
        // Return pending email if exists, otherwise null for success
        return pendingEmail != null ? 'PENDING_EMAIL:$pendingEmail' : null;
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to update profile';
        _isLoading = false;
        notifyListeners();
        return _errorMessage;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return _errorMessage;
    }
  }

  Future<String?> changePassword(String currentPassword, String newPassword) async {
    if (_token == null) return 'Not authenticated';
    
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/change-password');
      final response = await http.put(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'currentPassword': currentPassword,
          'newPassword': newPassword,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return null; // Success
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to change password';
        _isLoading = false;
        notifyListeners();
        return _errorMessage;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return _errorMessage;
    }
  }

  Future<String?> verifyCurrentEmailForChange(String currentEmailCode) async {
    if (_token == null) return 'Not authenticated';
    
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/verify-current-email-change');
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'currentEmailCode': currentEmailCode,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return null; // Success - returns pendingEmail in data
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to verify current email';
        _isLoading = false;
        notifyListeners();
        return _errorMessage;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return _errorMessage;
    }
  }

  Future<String?> verifyNewEmailForChange(String newEmailCode) async {
    if (_token == null) return 'Not authenticated';
    
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/verify-new-email-change');
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'newEmailCode': newEmailCode,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final user = data['user'];
        if (user != null) {
          _userEmail = user['email'] as String?;
          _userName = user['name'] as String?;
          _emailVerified = user['email_verified'] as bool?;
          
          // Update stored email
          if (_userEmail != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('user_email', _userEmail!);
          }
        }
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return null; // Success
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to verify new email';
        _isLoading = false;
        notifyListeners();
        return _errorMessage;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return _errorMessage;
    }
  }

  Future<String?> cancelEmailChange() async {
    if (_token == null) return 'Not authenticated';
    
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/cancel-email-change');
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return null; // Success
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to cancel email change';
        _isLoading = false;
        notifyListeners();
        return _errorMessage;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return _errorMessage;
    }
  }

  Future<bool> forgotPassword(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/forgot-password');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        // Success - always return true for security (don't reveal if email exists)
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to send password reset email';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> resetPassword(String code, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl).resolve('/api/auth/reset-password');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _errorMessage = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = data['error'] as String? ?? 'Failed to reset password';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Network error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }
}

enum _TokenCheck { valid, invalid, unknown }
