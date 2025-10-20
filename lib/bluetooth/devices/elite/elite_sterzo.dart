import 'dart:async';
import 'dart:convert';

import 'package:dartx/dartx.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swift_control/bluetooth/devices/base_device.dart';
import 'package:swift_control/utils/keymap/buttons.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../messages/notification.dart';

class EliteSterzo extends BaseDevice {
  EliteSterzo(super.scanResult)
    : super(
        availableButtons: [
          ControllerButton.navigationLeft,
          ControllerButton.navigationRight,
        ],
        isBeta: true,
      );

  double _lastAngle = 0.0;
  int? _latestChallenge;
  String? _serviceUuid;
  static Uint8List? _challengeCodesData;
  static bool _isLoadingChallenges = false;

  // Calibration state
  final List<double> _calibrationSamples = [];
  double _calibrationOffset = 0.0;
  bool _isCalibrated = false;

  // Last rounded angle for logging optimization
  int? _lastRoundedAngle;

  // Debounce timer for PWM-like keypress behavior
  Timer? _keypressTimer;
  bool _isProcessingKeypresses = false;

  @override
  Future<void> handleServices(List<BleService> services) async {
    final service = services.firstOrNullWhere(
      (e) => e.uuid.toLowerCase().startsWith('347b0'),
    );
    if (service == null) {
      throw Exception('Elite Sterzo service not found');
    }

    _serviceUuid = service.uuid;

    // Find characteristics
    final challengeChar = service.characteristics.firstOrNullWhere(
      (e) => e.uuid == SterzoConstants.CHALLENGE_CODE_CHARACTERISTIC_UUID,
    );
    final measurementChar = service.characteristics.firstOrNullWhere(
      (e) => e.uuid == SterzoConstants.MEASUREMENT_CHARACTERISTIC_UUID,
    );
    final controlChar = service.characteristics.firstOrNullWhere(
      (e) => e.uuid == SterzoConstants.CONTROL_POINT_CHARACTERISTIC_UUID,
    );

    if (challengeChar == null || measurementChar == null || controlChar == null) {
      throw Exception('Required Sterzo characteristics not found');
    }

    // Subscribe to challenge code indications
    await UniversalBle.subscribeNotifications(
      device.deviceId,
      service.uuid,
      challengeChar.uuid,
    );

    // Subscribe to measurement notifications
    await UniversalBle.subscribeNotifications(
      device.deviceId,
      service.uuid,
      measurementChar.uuid,
    );

    // Request to start challenge
    await UniversalBle.write(
      device.deviceId,
      service.uuid,
      controlChar.uuid,
      Uint8List.fromList([0x03, 0x10]),
      withoutResponse: false,
    );

    actionStreamInternal.add(LogNotification('Elite Sterzo: Initialization started'));
  }

  @override
  Future<void> processCharacteristic(String characteristic, Uint8List bytes) async {
    if (characteristic == SterzoConstants.CHALLENGE_CODE_CHARACTERISTIC_UUID) {
      _handleChallengeCode(bytes);
    } else if (characteristic == SterzoConstants.MEASUREMENT_CHARACTERISTIC_UUID) {
      _handleSteeringMeasurement(bytes);
    }
  }

  Future<void> _handleChallengeCode(Uint8List bytes) async {
    if (bytes.length >= 4) {
      // Challenge is in bytes 2-3 (big-endian)
      final challenge = (bytes[2] << 8) | bytes[3];
      _latestChallenge = challenge;

      actionStreamInternal.add(LogNotification('Elite Sterzo: Received challenge code: $challenge'));

      // Respond to challenge
      await _activateSteeringMeasurements();
    }
  }

  Future<void> _activateSteeringMeasurements() async {
    if (_latestChallenge == null || _serviceUuid == null) {
      return;
    }

    // Ensure challenge codes are loaded
    await _ensureChallengeCodesLoaded();

    // Get response codes for the challenge
    final challengeCodes = _getChallengeResponse(_latestChallenge!);

    // Send challenge response
    await UniversalBle.write(
      device.deviceId,
      _serviceUuid!,
      SterzoConstants.CONTROL_POINT_CHARACTERISTIC_UUID,
      Uint8List.fromList([0x03, 0x11, challengeCodes[0], challengeCodes[1]]),
      withoutResponse: false,
    );

    await Future.delayed(const Duration(seconds: 1));

    // Activate measurements
    await UniversalBle.write(
      device.deviceId,
      _serviceUuid!,
      SterzoConstants.CONTROL_POINT_CHARACTERISTIC_UUID,
      Uint8List.fromList([0x02, 0x02]),
      withoutResponse: false,
    );

    actionStreamInternal.add(LogNotification('Elite Sterzo: Steering measurements activated'));
  }

  static Future<void> _ensureChallengeCodesLoaded() async {
    if (_challengeCodesData != null) {
      return; // Already loaded
    }

    // Wait if already loading
    while (_isLoadingChallenges) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Check again after waiting
    if (_challengeCodesData != null) {
      return;
    }

    _isLoadingChallenges = true;

    try {
      if (kIsWeb) {
        // On web, always fetch from HTTP
        _challengeCodesData = await _fetchChallengeCodes();
      } else {
        // On native platforms, try to load from cache first
        _challengeCodesData = await _loadCachedChallengeCodes();

        if (_challengeCodesData == null) {
          // Cache miss - fetch from HTTP and cache it
          _challengeCodesData = await _fetchChallengeCodes();
          if (_challengeCodesData != null) {
            await _cacheChallengeCodes(_challengeCodesData!);
          }
        }
      }
    } finally {
      _isLoadingChallenges = false;
    }
  }

  static Future<Uint8List?> _fetchChallengeCodes() async {
    final url = kIsWeb
        ? 'https://corsproxy.io/${SterzoConstants.CHALLENGE_CODES_URL}'
        : SterzoConstants.CHALLENGE_CODES_URL;
    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      if (kDebugMode) {
        print('Failed to fetch challenge codes for URL $url: $e');
      }
    }
    return null;
  }

  static Future<Uint8List?> _loadCachedChallengeCodes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(SterzoConstants.CACHE_KEY);

      if (cached != null) {
        // Decode from base64
        return base64Decode(cached);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Failed to load cached challenge codes: $e');
      }
    }
    return null;
  }

  static Future<void> _cacheChallengeCodes(Uint8List data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Encode to base64 for storage
      await prefs.setString(SterzoConstants.CACHE_KEY, base64Encode(data));
    } catch (e) {
      if (kDebugMode) {
        print('Failed to cache challenge codes: $e');
      }
    }
  }

  void _handleSteeringMeasurement(Uint8List bytes) {
    if (bytes.length >= 4) {
      // Steering angle is a 32-bit float (little-endian)
      final rawAngle = ByteData.sublistView(bytes).getFloat32(0, Endian.little);

      // Ignore NaN readings during initial connection
      if (rawAngle.isNaN) {
        return;
      }

      // Handle calibration: collect initial samples to compute offset
      if (!_isCalibrated) {
        _calibrationSamples.add(rawAngle);
        if (_calibrationSamples.length >= SterzoConstants.CALIBRATION_SAMPLE_COUNT) {
          // Compute average offset from collected samples
          _calibrationOffset = _calibrationSamples.reduce((a, b) => a + b) / _calibrationSamples.length;
          _isCalibrated = true;
          actionStreamInternal.add(LogNotification(
            'Elite Sterzo: Calibration complete, offset: ${_calibrationOffset.toStringAsFixed(2)}°'
          ));
        }
        return; // Don't process steering during calibration
      }

      // Apply calibration offset
      final calibratedAngle = rawAngle - _calibrationOffset;

      // Round to whole degrees to reduce noise
      final roundedAngle = calibratedAngle.round();

      // Only log and process steering when rounded value changes to reduce verbosity
      if (_lastRoundedAngle != roundedAngle) {
        actionStreamInternal.add(LogNotification('Steering angle: $roundedAngle°'));
        _lastRoundedAngle = roundedAngle;

        // Apply PWM-like steering behavior only when angle changes
        _applyPWMSteering(roundedAngle);
      }

      _lastAngle = calibratedAngle;
    }
  }

  /// Applies PWM-like steering behavior with repeated keypresses proportional to angle magnitude
  void _applyPWMSteering(int roundedAngle) {
    // Cancel any pending keypress timer
    _keypressTimer?.cancel();

    // Determine if we're steering
    if (roundedAngle.abs() > SterzoConstants.STEERING_THRESHOLD) {
      // Determine direction
      final button = roundedAngle > 0 
        ? ControllerButton.navigationRight 
        : ControllerButton.navigationLeft;

      // Calculate number of keypress levels based on angle magnitude
      final levels = _calculateKeypressLevels(roundedAngle.abs());

      // Only trigger new keypresses when rounded angle changes to avoid overlap
      // The check for _lastRoundedAngle change is already done in _handleSteeringMeasurement
      // so we know this is a new angle value
      _scheduleRepeatedKeypresses(button, levels);
    } else {
      // Center position - release any held buttons
      handleButtonsClicked([]);
    }
  }

  /// Calculates the number of keypress levels based on angle magnitude
  int _calculateKeypressLevels(int absAngle) {
    final levels = (absAngle / SterzoConstants.LEVEL_DEGREE_STEP).floor();
    return levels.clamp(1, SterzoConstants.MAX_LEVELS);
  }

  /// Schedules repeated keypresses to simulate PWM behavior
  Future<void> _scheduleRepeatedKeypresses(ControllerButton button, int levels) async {
    // Don't overlap keypress sequences
    if (_isProcessingKeypresses) {
      return;
    }

    _isProcessingKeypresses = true;

    // Send keypresses in sequence with delays between them
    for (int i = 0; i < levels; i++) {
      await Future.delayed(Duration(milliseconds: SterzoConstants.KEY_REPEAT_INTERVAL_MS));
      handleButtonsClicked([button]);
    }

    _isProcessingKeypresses = false;
  }

  List<int> _getChallengeResponse(int challenge) {
    if (_challengeCodesData == null) {
      // Fallback if data not loaded
      return [0x96, 0x96];
    }

    final index = challenge * 2;
    if (index >= 0 && index < _challengeCodesData!.length - 1) {
      return [_challengeCodesData![index], _challengeCodesData![index + 1]];
    }

    // Fallback for out of range challenges
    return [0x96, 0x96];
  }

  @override
  Future<void> disconnect() async {
    _keypressTimer?.cancel();
    await super.disconnect();
  }
}

class SterzoConstants {
  static const String DEVICE_NAME = "STERZO";

  // Elite Sterzo Smart characteristic UUIDs
  static const String MEASUREMENT_CHARACTERISTIC_UUID = "347b0030-7635-408b-8918-8ff3949ce592";
  static const String CONTROL_POINT_CHARACTERISTIC_UUID = "347b0031-7635-408b-8918-8ff3949ce592";
  static const String CHALLENGE_CODE_CHARACTERISTIC_UUID = "347b0032-7635-408b-8918-8ff3949ce592";

  // Service UUID pattern (matches Elite devices)
  static const String SERVICE_UUID = "347b0001-7635-408b-8918-8ff3949ce592";

  // Steering angle threshold in degrees to trigger steering action
  static const double STEERING_THRESHOLD = 10.0;

  static const int RECONNECT_DELAY = 5; // seconds between reconnection attempts

  // URL to fetch challenge codes
  static const String CHALLENGE_CODES_URL =
      'https://github.com/zacharyedwardbull/pycycling/raw/refs/heads/master/pycycling/data/sterzo-challenge-codes.dat';

  // Cache key for SharedPreferences
  static const String CACHE_KEY = 'elite_sterzo_challenge_codes';

  // Calibration settings
  // Number of initial valid samples to collect for calibration offset
  static const int CALIBRATION_SAMPLE_COUNT = 10;

  // PWM-like steering behavior constants
  // Degrees per level for repeated keypress behavior
  static const double LEVEL_DEGREE_STEP = 10.0;
  // Maximum number of keypress levels
  static const int MAX_LEVELS = 5;
  // Interval between repeated keypresses in milliseconds
  static const int KEY_REPEAT_INTERVAL_MS = 40;
}
