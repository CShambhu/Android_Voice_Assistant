import 'dart:async';

import 'package:android_voice_assistant/choose_controls.dart';
import 'package:android_voice_assistant/services/wake_word_bridge.dart';
import 'package:android_voice_assistant/widget/choose_apps.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:android_voice_assistant/screens/guide_screens.dart';
import 'package:android_voice_assistant/services/accessibility_bridge.dart';
import 'package:android_voice_assistant/services/device_control_bridge.dart';

void main() {
  runApp(const HelloBossApp());
}

class VoiceController extends ChangeNotifier {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final TextEditingController textController = TextEditingController();

  bool _initialized = false;
  bool _available = false;
  bool _disposed = false;
  bool _actionInFlight = false;
  bool _launchInFlight = false;
  // Cache installed apps for faster subsequent launches.
  List<dynamic>? _installedAppsCache;

  List<ControlFeature> controlFeatures = [];
  final Set<String> selectedFeatures = {};
  bool featuresLoading = true;
  // Queue commands instead of dropping commands received close together.
  Future<void> _commandQueue = Future<void>.value();

  String _language = 'English';
  String _baseText = '';
  String _sessionText = '';

  bool micOn = false;
  bool loading = false;
  String error = '';

  /// Package names of the apps the user allowed Voice Assistant to control.
  Set<String> allowedPackages = <String>{};

  String _join(String a, String b) {
    if (a.trim().isEmpty) return b.trim();
    if (b.trim().isEmpty) return a.trim();
    return '${a.trim()} ${b.trim()}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _setText(String text) {
    if (_disposed) return;

    if (textController.text != text) {
      textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    _notify();
  }

  Future<void> _initialize() async {
    if (_initialized && _available) return;

    loading = true;
    error = '';
    _notify();

    try {
      _available = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
        debugLogging: false,
      );

      _initialized = true;

      if (!_available) {
        error =
            'Speech recognition is unavailable. Check your phone\'s '
            'speech recognition service.';
      }
    } catch (e) {
      _available = false;
      error = 'Could not initialize speech recognition: $e';
    } finally {
      loading = false;
      _notify();
    }
  }

  void _onStatus(String status) {
    if (_disposed) return;

    if (status == 'listening') {
      micOn = true;
    } else if (status == 'notListening' || status == 'done') {
      micOn = false;
    }

    _notify();
  }

  void _onError(SpeechRecognitionError result) {
    if (_disposed) return;

    micOn = false;
    error = 'Speech recognition error: ${result.errorMsg}';
    _notify();
  }

  void _onResult(SpeechRecognitionResult result) {
    if (_disposed) return;

    _sessionText = result.recognizedWords.trim();
    _setText(_join(_baseText, _sessionText));

    if (result.finalResult && !_launchInFlight) {
      unawaited(_finishAndExecute(_sessionText));
    }
  }

  Future<void> _finishAndExecute(String command) async {
    if (_disposed || _launchInFlight) return;

    _launchInFlight = true;

    try {
      await _speech.stop();

      if (_disposed) return;

      await _handleAppCommandInternal(command);
    } catch (e) {
      if (!_disposed) {
        error = 'Could not execute command: $e';
        _notify();
      }
    } finally {
      _launchInFlight = false;
    }
  }

  // Public entry point for commands received from WakeWordBridge.
  Future<void> handleAppCommand(String command) {
    if (_disposed || command.trim().isEmpty) {
      return Future<void>.value();
    }

    _commandQueue = _commandQueue.then((_) async {
      if (_disposed) return;

      try {
        await _handleAppCommandInternal(command);
      } catch (e) {
        if (!_disposed) {
          error = 'Could not execute command: $e';
          _notify();
        }
      }
    });

    return _commandQueue;
  }

  String _normalizeAppName(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Future<List<dynamic>> _getInstalledApps() async {
    if (_installedAppsCache != null) {
      return _installedAppsCache!;
    }

    final apps = await InstalledApps.getInstalledApps(
      excludeSystemApps: false,
      excludeNonLaunchableApps: true,
    );

    _installedAppsCache = apps;
    return apps;
  }

  Future<void> _handleAppCommandInternal(String spokenText) async {
    if (_disposed) return;

    final command = spokenText.trim();

    final match = RegExp(
      r'^(?:(?:hey|hello)\s+(?:boss|assistant)\s+)?'
      r'(?:(?:please)\s+)?'
      r'(?:open|launch|start|run)\s+(.+?)\s*[.!?]*$',
      caseSensitive: false,
    ).firstMatch(command);

    if (match == null) {
      error = 'Command not recognized: "$command"';
      _notify();
      return;
    }

    final requestedName = match.group(1)?.trim() ?? '';

    if (requestedName.isEmpty) return;

    try {
      error = '';
      _notify();

      // Only apps the user selected in "Choose your apps" may be opened.
      final apps = (await _getInstalledApps())
          .where((app) => allowedPackages.contains(app.packageName))
          .toList();

      if (_disposed) return;

      final requested = _normalizeAppName(requestedName);

      if (requested.isEmpty) {
        error = 'Please specify an app name.';
        _notify();
        return;
      }

      final exactMatches = apps.where((app) {
        return _normalizeAppName(app.name) == requested;
      }).toList();

      if (exactMatches.length == 1) {
        await _launchInstalledApp(exactMatches.first);
        return;
      }

      if (exactMatches.length > 1) {
        error = 'Multiple apps match "$requestedName".';
        _notify();
        return;
      }

      final partialMatches = apps.where((app) {
        final name = _normalizeAppName(app.name);
        return name.contains(requested) || requested.contains(name);
      }).toList();

      if (partialMatches.length == 1) {
        await _launchInstalledApp(partialMatches.first);
      } else if (partialMatches.isEmpty) {
        error = '"$requestedName" is not installed or cannot be launched.';
        _notify();
      } else {
        error =
            'Multiple apps match "$requestedName". '
            'Please say the full app name.';
        _notify();
      }
    } catch (e) {
      if (!_disposed) {
        error = 'Could not open "$requestedName": $e';
        _notify();
      }
    }
  }

  Future<void> _launchInstalledApp(dynamic app) async {
    if (_disposed) return;

    final String appName = app.name;
    final String packageName = app.packageName;

    if (packageName.isEmpty) {
      error = 'Could not find the app package.';
      _notify();
      return;
    }

    final launched = await InstalledApps.startApp(packageName);

    if (_disposed) return;

    error = launched == true ? '' : 'Could not launch $appName.';
    _notify();
  }

  String _localeForLanguage(String language) {
    switch (language) {
      case 'Nepali':
        return 'ne-NP';
      case 'Hindi':
        return 'hi-IN';
      default:
        return 'en-US';
    }
  }

  Future<void> setMic(bool on) async {
    if (_disposed || _actionInFlight || loading) return;
    if (on == micOn) return;

    _actionInFlight = true;

    try {
      if (on) {
        await _startListening();
      } else {
        await _stopListening();
      }
    } catch (e) {
      micOn = false;
      error = 'Speech recognition error: $e';
      _notify();
    } finally {
      _actionInFlight = false;
      _notify();
    }
  }

  Future<void> _startListening() async {
    error = '';
    await _initialize();

    if (!_available) {
      throw Exception(
        error.isNotEmpty ? error : 'Speech recognition is unavailable.',
      );
    }

    _baseText = textController.text.trim();
    _sessionText = '';

    final locales = await _speech.locales();
    final requestedLocale = _localeForLanguage(_language);

    String? localeId;

    for (final locale in locales) {
      if (locale.localeId.toLowerCase() == requestedLocale.toLowerCase()) {
        localeId = locale.localeId;
        break;
      }
    }

    if (localeId == null) {
      final languageCode = requestedLocale.split('-').first.toLowerCase();

      for (final locale in locales) {
        final installedLanguage = locale.localeId
            .split(RegExp(r'[-_]'))
            .first
            .toLowerCase();

        if (installedLanguage == languageCode) {
          localeId = locale.localeId;
          break;
        }
      }
    }

    if (localeId == null) {
      throw Exception(
        'No installed $_language speech recognition locale was found. '
        'Available locales: '
        '${locales.map((e) => e.localeId).join(', ')}',
      );
    }

    await _speech.listen(
      onResult: _onResult,
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 2),
        partialResults: true,
        cancelOnError: false,
        listenMode: stt.ListenMode.dictation,
      ),
    );

    if (!_speech.isListening) {
      throw Exception(
        'Could not start listening. Check microphone permission '
        'and your speech recognition service.',
      );
    }

    micOn = true;
    _notify();
  }

  Future<void> _stopListening() async {
    if (_speech.isListening) {
      await _speech.stop();
    }

    _setText(_join(_baseText, _sessionText));
    micOn = false;
    _notify();
  }

  Future<void> setLanguage(String language) async {
    if (!['English', 'Nepali', 'Hindi'].contains(language)) {
      error = '$language is not supported.';
      _notify();
      return;
    }

    _language = language;
    error = '';

    if (_initialized && _available) {
      try {
        final locales = await _speech.locales();
        final requested = _localeForLanguage(language);

        final found = locales.any(
          (locale) => locale.localeId.toLowerCase() == requested.toLowerCase(),
        );

        if (!found) {
          error =
              '$language ($requested) is not available in your '
              'phone\'s speech recognition service.';
        }
      } catch (e) {
        error = 'Could not check available languages: $e';
      }
    }

    _notify();
  }

  void clear() {
    _baseText = '';
    _sessionText = '';
    textController.clear();
    error = '';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    micOn = false;
    unawaited(_speech.cancel());
    textController.dispose();
    super.dispose();
  }
}

class HelloBossApp extends StatelessWidget {
  const HelloBossApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
      ),
      home: const SetupScreen(),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with WidgetsBindingObserver {
  final VoiceController voice = VoiceController();
  final WakeWordBridge wakeWord = WakeWordBridge();
  final AccessibilityBridge accessibility = AccessibilityBridge();
  bool _waitingForAccessibility = false;
  final DeviceControlBridge deviceControl = DeviceControlBridge();
  final TextEditingController _testController = TextEditingController();

  List<ControlFeature> controlFeatures = [];
  final Set<String> selectedFeatures = {};
  bool featuresLoading = true;

  bool writeSettingsOk = false;
  bool dndOk = false;
  String testResult = '';

  StreamSubscription<Map<String, dynamic>>? wakeSubscription;

  String wakeStatus = 'Wake word is off';
  String lastCommand = '';
  int wakeWordCount = 0;

  bool backgroundListening = false;
  bool wakeBusy = false;

  String selectedLanguage = 'English';
  bool rememberMe = true;

  // Every launchable app on the phone, and which ones the user ticked.
  // selectedApps holds PACKAGE NAMES (not display names).
  List<_InstalledApp> installedApps = [];
  final Set<String> selectedApps = {};
  bool appsLoading = true;
  String appSearch = '';
  final TextEditingController _searchController = TextEditingController();

  // Bumped whenever the app list changes so the "Choose your apps" page
  // (a separate screen) rebuilds with fresh data instead of a stale copy.
  final ValueNotifier<int> _appsRevision = ValueNotifier<int>(0);

  // Continue setup automatically when the user returns from Settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    unawaited(_refreshDevicePermissions());

    if (_waitingForAccessibility) {
      _waitingForAccessibility = false;

      accessibility.isEnabled().then((enabled) {
        if (enabled && mounted && !wakeBusy) {
          unawaited(_getStarted());
        }
      });
    }
  }

  Future<void> _refreshDevicePermissions() async {
    try {
      final w = await deviceControl.hasWriteSettings();
      final d = await deviceControl.hasDndAccess();
      if (!mounted) return;
      setState(() {
        writeSettingsOk = w;
        dndOk = d;
      });
    } catch (_) {}
  }

  Future<void> _loadFeatures() async {
    try {
      final available = await deviceControl.getFeatures();
      final saved = await deviceControl.getAllowedFeatures();
      final ids = available.map((f) => f.id).toSet();

      if (!mounted) return;

      setState(() {
        controlFeatures = available;
        selectedFeatures
          ..clear()
          ..addAll(saved.where(ids.contains));
        featuresLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        featuresLoading = false;
        wakeStatus = 'Could not check phone controls: $e';
      });
    }
  }

  void _saveFeatureSelection() {
    unawaited(
      deviceControl.setAllowedFeatures(selectedFeatures).catchError((Object e) {
        if (!mounted) return;
        setState(() {
          wakeStatus = 'Could not save phone controls: $e';
        });
      }),
    );
  }

  IconData _featureIcon(String id) {
    switch (id) {
      case 'FLASHLIGHT':
        return Icons.flashlight_on;
      case 'SCREENSHOT':
        return Icons.screenshot;
      case 'WIFI':
        return Icons.wifi;
      case 'BLUETOOTH':
        return Icons.bluetooth;
      case 'LOCATION':
        return Icons.location_on;
      case 'AUTO_ROTATE':
        return Icons.screen_rotation;
      case 'AIRPLANE':
        return Icons.airplanemode_active;
      case 'HOTSPOT':
        return Icons.wifi_tethering;
      case 'MOBILE_DATA':
        return Icons.signal_cellular_alt;
      case 'QR_SCANNER':
        return Icons.qr_code_scanner;
      case 'BATTERY_SAVER':
        return Icons.battery_saver;
      case 'DND':
        return Icons.do_not_disturb_on;
      case 'SCREEN_RECORD':
        return Icons.videocam;
      case 'NFC':
        return Icons.nfc;
      case 'DARK_MODE':
        return Icons.dark_mode;
      case 'CAST':
        return Icons.cast;
      case 'QUICK_SHARE':
        return Icons.share;
      case 'DATA_SAVER':
        return Icons.data_saver_on;
      default:
        return Icons.settings;
    }
  }

  // Returns true only when Accessibility is already ON.
  // Otherwise explains the steps, opens Settings, and returns false.
  Future<bool> _ensureAccessibility() async {
    if (await accessibility.isEnabled()) return true;
    if (!mounted) return false;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Turn on Accessibility'),
        content: const Text(
          'Accessibility is needed so Voice Assistant can control your '
          'selected apps.\n\n'
          'Settings > Accessibility > Installed apps > '
          'Hello Boss Voice Controls > turn ON > Allow.',
        ),

        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        actions: [
          Row(
            children: [
              Expanded(
                flex: 4,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, 'settings'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 42),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Open Settings'),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 3,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, 'appinfo'),
                  child: const Text('App info'),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 3,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, 'cancel'),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (choice == 'settings' || choice == 'appinfo') {
      _waitingForAccessibility = choice == 'settings';

      try {
        if (choice == 'settings') {
          await accessibility.openSettings();
        } else {
          await accessibility.openAppInfo();
        }
      } catch (e) {
        _waitingForAccessibility = false;
        if (mounted) {
          setState(() {
            wakeStatus = 'Could not open settings: $e';
          });
        }
      }
    }

    return false;
  }

  Future<void> _loadApps() async {
    try {
      // Start both lookups at once instead of one after the other.
      final savedFuture = wakeWord.getAllowedApps();
      final appsFuture = wakeWord.getLaunchableApps();

      final saved = await savedFuture;
      final all = await appsFuture;

      final list = <_InstalledApp>[
        for (final app in all)
          if (app['package']!.isNotEmpty &&
              app['package'] != 'com.example.android_voice_assistant')
            _InstalledApp(app['name']!, app['package']!),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      // Forget saved apps that have since been uninstalled.
      final installed = list.map((app) => app.packageName).toSet();
      final stillInstalled = saved.where(installed.contains).toSet();

      if (!mounted) return;

      setState(() {
        installedApps = list;
        selectedApps
          ..clear()
          ..addAll(stillInstalled);
        appsLoading = false;
      });

      _appsRevision.value++;

      voice.allowedPackages = {...selectedApps};
    } catch (e) {
      if (!mounted) return;

      setState(() {
        appsLoading = false;
        wakeStatus = 'Could not load your apps: $e';
      });

      _appsRevision.value++;
    }
  }

  Widget _letterAvatar(_InstalledApp app, ColorScheme colors, double size) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: colors.primary.withAlpha(25),
      foregroundColor: colors.primary,
      child: Text(
        app.name.isEmpty ? '?' : app.name.characters.first.toUpperCase(),
      ),
    );
  }

  // Icons are fetched natively one at a time, only for rows being shown,
  // and cached here so scrolling doesn't reload them.
  final Map<String, Future<Uint8List?>> _iconFutures = {};

  // The app's real launcher icon; falls back to its first letter.
  Widget _appIcon(_InstalledApp app, ColorScheme colors, {double size = 42}) {
    final future = _iconFutures.putIfAbsent(
      app.packageName,
      () => wakeWord.getAppIcon(app.packageName).catchError((Object _) => null),
    );

    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final icon = snapshot.data;

        if (icon == null || icon.isEmpty) {
          return _letterAvatar(app, colors, size);
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.25),
          child: Image.memory(
            icon,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _letterAvatar(app, colors, size),
          ),
        );
      },
    );
  }

  // Horizontal strip of the apps already selected, with a remove button.

  // "Get Started": set everything up, start the background listener, then
  // close this screen. The listener is a foreground service, so it keeps
  // working after this screen closes or is cleared from Recents.
  Future<void> _getStarted() async {
    debugPrint('GET STARTED BUTTON CLICKED');
    // Can't start without at least one selected app.
    if (selectedApps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one app.')),
      );
      return;
    }

    setState(() {
      wakeBusy = true;
    });

    try {
      final mic = await Permission.microphone.request();

      if (!mic.isGranted) {
        if (!mounted) return;

        setState(() {
          wakeStatus = mic.isPermanentlyDenied
              ? 'Microphone permission is permanently denied.'
              : 'Microphone permission is required.';
        });

        if (mic.isPermanentlyDenied) {
          await openAppSettings();
        }
        return;
      }

      // Ask for these, but don't block Get Started if they are declined.
      await Permission.notification.request();

      if (!await Permission.systemAlertWindow.isGranted) {
        await Permission.systemAlertWindow.request();
      }

      // Stops battery saving from killing the listener in the background.
      // if (!await Permission.ignoreBatteryOptimizations.isGranted) {
      //   await Permission.ignoreBatteryOptimizations.request();
      // }

      // NEW: Accessibility must be ON before the assistant starts.
      if (!await _ensureAccessibility()) return;
      await deviceControl.setAllowedFeatures(selectedFeatures);
      await wakeWord.setAllowedApps(selectedApps);
      await wakeWord.setLanguage(selectedLanguage);
      await wakeWord.start();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice Assistant is listening in the background.'),
        ),
      );

      // Let the message show for a moment, then close this screen.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await SystemNavigator.pop();
    } on PlatformException catch (e) {
      if (!mounted) return;

      setState(() {
        wakeStatus = e.message ?? 'Could not start Voice Assistant';
        backgroundListening = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        wakeStatus = 'Error: $e';
        backgroundListening = false;
      });
    } finally {
      if (mounted) {
        setState(() {
          wakeBusy = false;
        });
      }
    }
  }

  // Saved natively so the background service enforces it immediately.
  void _saveSelection() {
    voice.allowedPackages = {...selectedApps};

    unawaited(
      wakeWord.setAllowedApps(selectedApps).catchError((Object e) {
        if (!mounted) return;

        setState(() {
          wakeStatus = 'Could not save app selection: $e';
        });
      }),
    );
  }

  // One button: turns the microphone (wake-word listening) on or off.
  Future<void> _toggleMicrophone() async {
    debugPrint('MICROPHONE BUTTON CLICKED');
    if (wakeBusy) return;

    if (backgroundListening) {
      await _turnMicOff();
    } else {
      await _turnMicOn();
    }
  }

  Future<void> _turnMicOn() async {
    // Hello Boss can't run without apps.
    if (selectedApps.isEmpty) {
      setState(() {
        wakeStatus = 'Select at least one app first.';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one app.')),
      );
      return;
    }

    setState(() {
      wakeBusy = true;
    });

    try {
      final status = await Permission.microphone.request();

      if (!status.isGranted) {
        if (!mounted) return;

        setState(() {
          wakeStatus = status.isPermanentlyDenied
              ? 'Microphone permission is permanently denied.'
              : 'Microphone permission is required.';
        });

        if (status.isPermanentlyDenied) {
          await openAppSettings();
        }
        return;
      }

      // Needed so Hello Boss can open an app while another app is on screen
      // (Android blocks background launches).
      if (!await Permission.systemAlertWindow.isGranted) {
        await Permission.systemAlertWindow.request();
      }

      await wakeWord.setAllowedApps(selectedApps);
      await wakeWord.setLanguage(selectedLanguage);
      await wakeWord.start();

      if (!mounted) return;

      setState(() {
        backgroundListening = true;
        wakeStatus = 'Starting listener...';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;

      setState(() {
        wakeStatus = e.message ?? 'Could not turn on the microphone';
        backgroundListening = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        wakeStatus = 'Error: $e';
        backgroundListening = false;
      });
    } finally {
      if (mounted) {
        setState(() {
          wakeBusy = false;
        });
      }
    }
  }

  Future<void> _turnMicOff() async {
    setState(() {
      wakeBusy = true;
    });

    try {
      // Stop the native wake-word service.
      await wakeWord.stop();

      // Also stop Flutter speech recognition.
      await voice.setMic(false);

      if (!mounted) return;

      setState(() {
        backgroundListening = false;
        wakeStatus = 'Microphone turned off';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        wakeStatus = 'Could not turn off microphone: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          wakeBusy = false;
        });
      }
    }
  }

  // The listener may already be running (e.g. started with Get Started and
  // this screen reopened), so ask it instead of assuming "off".
  Future<void> _syncListeningState() async {
    try {
      final on = await wakeWord.isListening();

      if (!mounted) return;

      setState(() {
        backgroundListening = on;
        if (on) wakeStatus = 'listening';
      });
    } catch (_) {
      // Keep the default (off) if the service can't be asked.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadApps());
    unawaited(_syncListeningState());
    unawaited(_loadFeatures());
    unawaited(_refreshDevicePermissions());

    wakeSubscription = wakeWord.events.listen(
      (event) {
        if (!mounted) return;

        final type = event['type'] as String? ?? '';
        final value = event['value'] as String? ?? '';

        setState(() {
          switch (type) {
            case 'status':
              wakeStatus = value;

              // Only these change whether the mic is on. Other messages
              // (e.g. "Opened WhatsApp") must not flip the button.
              if (value == 'listening' || value == 'command') {
                backgroundListening = true;
              } else if (value == 'stopped') {
                backgroundListening = false;
              }
              break;

            case 'wakeWord':
              wakeWordCount++;
              wakeStatus = 'Wake word detected';
              break;

            case 'command':
              lastCommand = value;
              wakeStatus = 'Command recognized: $value';
              break;

            case 'launched':
              wakeStatus = 'Opened $value';
              break;

            case 'error':
              // An error message doesn't mean the mic turned off; the
              // service reports 'stopped' when it really stops.
              wakeStatus = value;
              break;
          }
        });

        // Execute commands received from WakeWordBridge.
        // The bridge must emit the actual recognized command.
        // if (type == 'command' && value.trim().isNotEmpty) {
        //   unawaited(voice.handleAppCommand(value));
        // }
      },
      onError: (Object error) {
        if (!mounted) return;

        setState(() {
          wakeStatus = 'Wake-word connection error: $error';
          backgroundListening = false;
        });
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    wakeSubscription?.cancel();
    _searchController.dispose();
    _appsRevision.dispose();
    voice.dispose();
    _testController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F5FC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Icon(
                          Icons.graphic_eq,
                          size: 42,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        'Voice Assistant',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: colors.primary,
                        ),
                      ),
                      Text(
                        'Your phone, your voice, your assistant.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                const Text(
                  'Choose your language',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),

                DropdownButtonFormField<String>(
                  initialValue: selectedLanguage,
                  isExpanded: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.language),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'English', child: Text('English')),
                    DropdownMenuItem(
                      value: 'Nepali',
                      child: Text('नेपाली (Nepali)'),
                    ),
                    DropdownMenuItem(
                      value: 'Hindi',
                      child: Text('हिन्दी (Hindi)'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        selectedLanguage = value;
                      });

                      unawaited(voice.setLanguage(value));
                    }
                  },
                ),

                const SizedBox(height: 12),
                // Choose your apps button
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          // Rebuilds when the app list finishes loading.
                          builder: (context) => ValueListenableBuilder<int>(
                            valueListenable: _appsRevision,
                            builder: (context, _, _) => ChooseApps(
                              colors: colors,
                              selectedApps: selectedApps,
                              installedApps: installedApps,
                              appsLoading: appsLoading,
                              searchController: _searchController,
                              onSearchChanged: (value) {
                                appSearch = value;
                              },
                              onAppSelectionChanged: (packageName, checked) {
                                setState(() {
                                  if (checked) {
                                    selectedApps.add(packageName);
                                  } else {
                                    selectedApps.remove(packageName);
                                  }
                                });
                              },
                              onBulkSelectionChanged: (packages, checked) {
                                setState(() {
                                  if (checked) {
                                    selectedApps.addAll(packages);
                                  } else {
                                    selectedApps.removeAll(packages);
                                  }
                                });
                              },
                              appIcon: (app, colors, {double size = 42}) {
                                return _appIcon(
                                  app as _InstalledApp,
                                  colors,
                                  size: size,
                                );
                              },
                              onSaveSelection: _saveSelection,
                            ),
                          ),
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.primary,
                      side: BorderSide(
                        color: colors.primary.withAlpha(100),
                        width: 1.3,
                      ),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.apps_rounded,
                          size: 23,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Text(
                            'Choose your apps',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 15,
                          color: colors.primary.withAlpha(160),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Choose your controls button
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => ChooseControls(
                            colors: colors,
                            selectedFeatures: selectedFeatures,
                            controlFeatures: controlFeatures,
                            featuresLoading: featuresLoading,
                            writeSettingsOk: writeSettingsOk,
                            dndOk: dndOk,
                            testResult: testResult,
                            featureIcon: _featureIcon,
                            onSaveFeatureSelection: _saveFeatureSelection,
                            onOpenWriteSettings: () {
                              deviceControl.openWriteSettings();
                            },
                            onOpenDndAccess: () {
                              deviceControl.openDndAccess();
                            },
                            onFeatureSelectionChanged: (id) {
                              setState(() {
                                if (selectedFeatures.contains(id)) {
                                  selectedFeatures.remove(id);
                                } else {
                                  selectedFeatures.add(id);
                                }
                              });
                            },
                            onSelectAll: () {
                              setState(() {
                                selectedFeatures
                                  ..clear()
                                  ..addAll(controlFeatures.map((f) => f.id));
                              });
                            },
                            onClearAll: () {
                              setState(() {
                                selectedFeatures.clear();
                              });
                            },
                          ),
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.primary,
                      side: BorderSide(
                        color: colors.primary.withAlpha(100),
                        width: 1.3,
                      ),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          size: 23,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Text(
                            'Choose your controls',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 15,
                          color: colors.primary.withAlpha(160),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            // Icon(Icons.hearing),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Background wake word',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        Text('Status: $wakeStatus'),

                        const SizedBox(height: 4),

                        Text('Wake-word detections: $wakeWordCount'),

                        if (lastCommand.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text('Last command: $lastCommand'),
                        ],

                        if (voice.error.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            voice.error,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],

                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: backgroundListening
                                  ? const Color(0xFFC62828) // Deep red
                                  : const Color(0xFF2E7D32), // Emerald green
                              foregroundColor: backgroundListening
                                  ? Colors.white
                                  : null,
                            ),
                            onPressed: wakeBusy ? null : _toggleMicrophone,
                            icon: Icon(
                              backgroundListening ? Icons.mic_off : Icons.mic,
                            ),
                            label: Text(
                              backgroundListening
                                  ? 'Turn off microphone'
                                  : 'Turn on microphone',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Remember me',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  value: rememberMe,
                  activeColor: colors.primary,
                  onChanged: (value) {
                    setState(() {
                      rememberMe = value ?? false;
                    });
                  },
                ),

                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: wakeBusy ? null : _getStarted,
                    icon: const Icon(Icons.arrow_forward, size: 22),
                    label: const Text(
                      'Get Started',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const GuideScreen()),
                      );
                    },
                    icon: const Icon(Icons.help_outline, size: 22),
                    label: const Text('Help / Guide'),
                  ),
                ),

                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InstalledApp {
  final String name;
  final String packageName;
  final Uint8List? icon;

  const _InstalledApp(this.name, this.packageName) : icon = null;
}
