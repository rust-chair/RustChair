import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../utils/http_service.dart' as http;
import 'model.dart';
import 'platform_model.dart';

bool refreshingUser = false;

enum AuthState {
  loggedOut,
  restoring,
  authenticated,
  offlineAuthenticated,
}

enum TokenRefreshResult {
  success,
  invalid,
  unavailable,
}

class UserModel {
  final RxString userName = ''.obs;
  final RxString displayName = ''.obs;
  final RxString avatar = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString networkError = ''.obs;
  final RxList<AccountDevice> devices = <AccountDevice>[].obs;
  final RxBool devicesLoading = false.obs;
  final RxString devicesError = ''.obs;
  final Rx<AuthState> authState = AuthState.loggedOut.obs;
  bool get isLogin =>
      authState.value != AuthState.loggedOut && userName.isNotEmpty;
  String get displayNameOrUserName =>
      displayName.value.trim().isEmpty ? userName.value : displayName.value;
  String get accountLabelWithHandle {
    final username = userName.value.trim();
    if (username.isEmpty) {
      return '';
    }
    final preferred = displayName.value.trim();
    if (preferred.isEmpty || preferred == username) {
      return username;
    }
    return '$preferred (@$username)';
  }

  WeakReference<FFI> parent;

  UserModel(this.parent) {
    userName.listen((p0) {
      // When user name becomes empty, show login button
      // When user name becomes non-empty:
      //  For _updateLocalUserInfo, network error will be set later
      //  For login success, should clear network error
      networkError.value = '';
    });
  }

  Future<void> refreshCurrentUser() async {
    if (bind.isDisableAccount()) return;
    networkError.value = '';
    var token = bind.mainGetLocalOption(key: 'access_token');
    if (token == '') {
      authState.value = AuthState.loggedOut;
      await updateOtherModels();
      return;
    }
    _updateLocalUserInfo();
    authState.value = AuthState.restoring;
    final url = await bind.mainGetApiServer();
    final body = {
      'id': await bind.mainGetMyId(),
      'uuid': await bind.mainGetUuid()
    };
    if (refreshingUser) return;
    try {
      refreshingUser = true;
      http.Response response;
      try {
        if (_accessTokenNeedsRefresh()) {
          final result = await refreshAccessToken(apiServer: url);
          if (result == TokenRefreshResult.invalid) {
            await reset(resetOther: true);
            return;
          }
          if (result == TokenRefreshResult.unavailable) {
            authState.value = AuthState.offlineAuthenticated;
            return;
          }
          token = bind.mainGetLocalOption(key: 'access_token');
        }
        response = await http.post(Uri.parse('$url/api/currentUser'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token'
            },
            body: json.encode(body));
        if (response.statusCode == 401) {
          final result = await refreshAccessToken(apiServer: url);
          if (result == TokenRefreshResult.success) {
            token = bind.mainGetLocalOption(key: 'access_token');
            response = await http.post(Uri.parse('$url/api/currentUser'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token'
                },
                body: json.encode(body));
          } else if (result == TokenRefreshResult.unavailable) {
            authState.value = AuthState.offlineAuthenticated;
            return;
          }
        }
      } catch (e) {
        networkError.value = e.toString();
        if (userName.isNotEmpty) {
          authState.value = AuthState.offlineAuthenticated;
        }
        rethrow;
      }
      refreshingUser = false;
      final status = response.statusCode;
      if (status == 401 || status == 400) {
        await reset(resetOther: status == 401);
        return;
      }
      final data = json.decode(decode_http_response(response));
      final error = data['error'];
      if (error != null) {
        throw error;
      }

      final user = UserPayload.fromJson(data);
      _parseAndUpdateUser(user);
      authState.value = AuthState.authenticated;
    } catch (e) {
      if (userName.isNotEmpty && authState.value == AuthState.restoring) {
        networkError.value = e.toString();
        authState.value = AuthState.offlineAuthenticated;
      }
      debugPrint('Failed to refreshCurrentUser: $e');
    } finally {
      refreshingUser = false;
      await updateOtherModels();
    }
  }

  static Map<String, dynamic>? getLocalUserInfo() {
    final userInfo = bind.mainGetLocalOption(key: 'user_info');
    if (userInfo == '') {
      return null;
    }
    try {
      return json.decode(userInfo);
    } catch (e) {
      debugPrint('Failed to get local user info "$userInfo": $e');
    }
    return null;
  }

  _updateLocalUserInfo() {
    final userInfo = getLocalUserInfo();
    if (userInfo != null) {
      userName.value = (userInfo['name'] ?? '').toString();
      displayName.value = (userInfo['display_name'] ?? '').toString();
      avatar.value = (userInfo['avatar'] ?? '').toString();
    }
  }

  Future<void> reset({bool resetOther = false}) async {
    await bind.mainSetLocalOption(key: 'access_token', value: '');
    await bind.mainSetLocalOption(key: 'refresh_token', value: '');
    await bind.mainSetLocalOption(key: 'access_token_expires_at', value: '');
    await bind.mainSetLocalOption(key: 'account_device_id', value: '');
    await bind.mainSetLocalOption(key: 'account_mode', value: '');
    await bind.mainSetLocalOption(key: 'user_info', value: '');
    if (resetOther) {
      await gFFI.abModel.reset();
      await gFFI.groupModel.reset();
    }
    userName.value = '';
    displayName.value = '';
    avatar.value = '';
    devices.clear();
    devicesError.value = '';
    isAdmin.value = false;
    authState.value = AuthState.loggedOut;
  }

  _parseAndUpdateUser(UserPayload user) {
    userName.value = user.name;
    displayName.value = user.displayName;
    avatar.value = user.avatar;
    isAdmin.value = user.isAdmin;
    bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    if (isWeb) {
      // ugly here, tmp solution
      bind.mainSetLocalOption(key: 'verifier', value: user.verifier ?? '');
    }
  }

  // update ab and group status
  static Future<void> updateOtherModels() async {
    if (bind.mainGetLocalOption(key: 'account_mode') == 'personal') {
      await gFFI.userModel.loadDevices(quiet: true);
      return;
    }
    await Future.wait([
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: false),
      gFFI.groupModel.pull(),
      gFFI.userModel.loadDevices(quiet: true),
    ]);
  }

  Future<void> logOut({String? apiServer}) async {
    final tag = gFFI.dialogManager.showLoading(translate('Waiting'));
    try {
      final url = apiServer ?? await bind.mainGetApiServer();
      final authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      await http
          .post(Uri.parse('$url/api/logout'),
              body: jsonEncode({
                'id': await bind.mainGetMyId(),
                'uuid': await bind.mainGetUuid(),
              }),
              headers: authHeaders)
          .timeout(Duration(seconds: 2));
    } catch (e) {
      debugPrint("request /api/logout failed: err=$e");
    } finally {
      await reset(resetOther: true);
      gFFI.dialogManager.dismissByTag(tag);
    }
  }

  /// throw [RequestException]
  Future<LoginResponse> login(LoginRequest loginRequest) async {
    final url = await bind.mainGetApiServer();
    final resp = await http.post(Uri.parse('$url/api/login'),
        body: jsonEncode(loginRequest.toJson()));

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(decode_http_response(resp));
    } catch (e) {
      debugPrint("login: jsonDecode resp body failed: ${e.toString()}");
      if (resp.statusCode != 200) {
        BotToast.showText(
            contentColor: Colors.red, text: 'HTTP ${resp.statusCode}');
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw RequestException(resp.statusCode, body['error'] ?? '');
    }
    if (body['error'] != null) {
      throw RequestException(0, body['error']);
    }

    return getLoginResponseFromAuthBody(body);
  }

  LoginResponse getLoginResponseFromAuthBody(Map<String, dynamic> body) {
    final LoginResponse loginResponse;
    try {
      loginResponse = LoginResponse.fromJson(body);
    } catch (e) {
      debugPrint("login: jsonDecode LoginResponse failed: ${e.toString()}");
      rethrow;
    }

    final isLogInDone = loginResponse.type == HttpType.kAuthResTypeToken &&
        loginResponse.access_token != null;
    if (isLogInDone && loginResponse.user != null) {
      _parseAndUpdateUser(loginResponse.user!);
      authState.value = AuthState.authenticated;
    }

    return loginResponse;
  }

  Future<void> persistLoginResponse(LoginResponse response) async {
    final accessToken = response.access_token;
    if (accessToken == null || accessToken.isEmpty) return;
    await bind.mainSetLocalOption(key: 'access_token', value: accessToken);
    final refreshToken = response.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await bind.mainSetLocalOption(key: 'refresh_token', value: refreshToken);
    }
    final expiresIn = response.expiresIn;
    if (expiresIn != null && expiresIn > 0) {
      final expiresAt =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn;
      await bind.mainSetLocalOption(
          key: 'access_token_expires_at', value: expiresAt.toString());
    }
    final deviceId = response.deviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      await bind.mainSetLocalOption(key: 'account_device_id', value: deviceId);
    }
    await bind.mainSetLocalOption(
        key: 'account_mode', value: response.accountMode ?? '');
    if (response.user != null) {
      await bind.mainSetLocalOption(
          key: 'user_info', value: jsonEncode(response.user));
      _parseAndUpdateUser(response.user!);
    }
    authState.value = AuthState.authenticated;
  }

  bool _accessTokenNeedsRefresh() {
    final raw = bind.mainGetLocalOption(key: 'access_token_expires_at');
    final expiresAt = int.tryParse(raw);
    if (expiresAt == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return expiresAt <= now + 60;
  }

  Future<TokenRefreshResult> refreshAccessToken({String? apiServer}) async {
    final refreshToken = bind.mainGetLocalOption(key: 'refresh_token');
    if (refreshToken.isEmpty) return TokenRefreshResult.invalid;
    try {
      final url = apiServer ?? await bind.mainGetApiServer();
      final response = await http.post(Uri.parse('$url/api/token/refresh'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}));
      if (response.statusCode == 400 || response.statusCode == 401) {
        return TokenRefreshResult.invalid;
      }
      if (response.statusCode != 200) return TokenRefreshResult.unavailable;
      final body = jsonDecode(decode_http_response(response));
      final loginResponse = getLoginResponseFromAuthBody(body);
      await persistLoginResponse(loginResponse);
      return loginResponse.access_token?.isNotEmpty == true
          ? TokenRefreshResult.success
          : TokenRefreshResult.invalid;
    } catch (e) {
      debugPrint('Failed to refresh access token: $e');
      return TokenRefreshResult.unavailable;
    }
  }

  Future<bool> ensureValidAccessToken() async {
    if (!isLogin || !_accessTokenNeedsRefresh()) return true;
    final result = await refreshAccessToken();
    if (result == TokenRefreshResult.invalid) {
      await reset(resetOther: true);
    } else if (result == TokenRefreshResult.unavailable) {
      authState.value = AuthState.offlineAuthenticated;
    }
    return result == TokenRefreshResult.success;
  }

  Future<void> loadDevices({bool quiet = false}) async {
    if (!isLogin || devicesLoading.value) return;
    devicesLoading.value = true;
    if (!quiet) devicesError.value = '';
    try {
      final url = await bind.mainGetApiServer();
      var response = await http.get(Uri.parse('$url/api/devices'),
          headers: getHttpHeaders());
      if (response.statusCode == 401) {
        final result = await refreshAccessToken(apiServer: url);
        if (result == TokenRefreshResult.success) {
          response = await http.get(Uri.parse('$url/api/devices'),
              headers: getHttpHeaders());
        } else if (result == TokenRefreshResult.unavailable) {
          throw RequestException(0, 'Account server is unavailable');
        }
      }
      if (response.statusCode == 401) {
        await reset(resetOther: true);
        return;
      }
      if (response.statusCode != 200) {
        throw RequestException(response.statusCode,
            jsonDecode(decode_http_response(response))['error'] ?? '');
      }
      final body = jsonDecode(decode_http_response(response));
      final values = body['devices'] as List<dynamic>? ?? const [];
      devices.assignAll(
          values.whereType<Map<String, dynamic>>().map(AccountDevice.fromJson));
    } catch (e) {
      if (!quiet) devicesError.value = e.toString();
      debugPrint('Failed to load account devices: $e');
    } finally {
      devicesLoading.value = false;
    }
  }

  Future<bool> renameDevice(String deviceId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final url = await bind.mainGetApiServer();
    final headers = getHttpHeaders()..['Content-Type'] = 'application/json';
    var response = await http.put(Uri.parse('$url/api/devices/$deviceId'),
        headers: headers, body: jsonEncode({'name': trimmed}));
    if (response.statusCode == 401 &&
        await refreshAccessToken(apiServer: url) ==
            TokenRefreshResult.success) {
      response = await http.put(Uri.parse('$url/api/devices/$deviceId'),
          headers: getHttpHeaders()..['Content-Type'] = 'application/json',
          body: jsonEncode({'name': trimmed}));
    }
    if (response.statusCode != 204) return false;
    await loadDevices();
    return true;
  }

  Future<bool> revokeDevice(AccountDevice device) async {
    final url = await bind.mainGetApiServer();
    var response = await http.delete(Uri.parse('$url/api/devices/${device.id}'),
        headers: getHttpHeaders());
    if (response.statusCode == 401 &&
        await refreshAccessToken(apiServer: url) ==
            TokenRefreshResult.success) {
      response = await http.delete(Uri.parse('$url/api/devices/${device.id}'),
          headers: getHttpHeaders());
    }
    if (response.statusCode != 204) return false;
    if (device.isCurrent) {
      await reset(resetOther: true);
    } else {
      await loadDevices();
    }
    return true;
  }

  static Future<List<dynamic>> queryOidcLoginOptions() async {
    try {
      final url = await bind.mainGetApiServer();
      if (url.trim().isEmpty) return [];
      final resp = await http.get(Uri.parse('$url/api/login-options'));
      final List<String> ops = [];
      for (final item in jsonDecode(resp.body)) {
        ops.add(item as String);
      }
      for (final item in ops) {
        if (item.startsWith('common-oidc/')) {
          return jsonDecode(item.substring('common-oidc/'.length));
        }
      }
      return ops
          .where((item) => item.startsWith('oidc/'))
          .map((item) => {'name': item.substring('oidc/'.length)})
          .toList();
    } catch (e) {
      debugPrint(
          "queryOidcLoginOptions: jsonDecode resp body failed: ${e.toString()}");
      return [];
    }
  }
}

class AccountDevice {
  final String id;
  final String rustdeskId;
  final String name;
  final String os;
  final String type;
  final int lastSeenAt;
  final bool isCurrent;
  final bool online;

  const AccountDevice({
    required this.id,
    required this.rustdeskId,
    required this.name,
    required this.os,
    required this.type,
    required this.lastSeenAt,
    required this.isCurrent,
    required this.online,
  });

  factory AccountDevice.fromJson(Map<String, dynamic> json) => AccountDevice(
        id: json['id']?.toString() ?? '',
        rustdeskId: json['rustdesk_id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        os: json['os']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
        lastSeenAt: json['last_seen_at'] as int? ?? 0,
        isCurrent: json['is_current'] == true,
        online: json['online'] == true,
      );
}
