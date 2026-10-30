import 'dart:async';

import 'package:android_voice_assistant/services/wake_word_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:android_voice_assistant/screens/guide_screens.dart';
import 'package:android_voice_assistant/services/accessibility_bridge.dart';

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

  List<_InstalledApp> get _visibleApps {
    final query = appSearch.trim().toLowerCase();
    if (query.isEmpty) return installedApps;

    return installedApps
        .where((app) => app.name.toLowerCase().contains(query))
        .toList();
  }

  // Continue setup automatically when the user returns from Settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForAccessibility) {
      _waitingForAccessibility = false;

      accessibility.isEnabled().then((enabled) {
        if (enabled && mounted && !wakeBusy) {
          unawaited(_getStarted());
        }
      });
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

      final list =
          <_InstalledApp>[
            for (final app in all)
              if (app['package']!.isNotEmpty &&
                  app['package'] != 'com.example.android_voice_assistant')
                _InstalledApp(app['name']!, app['package']!),
          ]..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          ); // Forget saved apps that have since been uninstalled.
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

      voice.allowedPackages = {...selectedApps};
    } catch (e) {
      if (!mounted) return;

      setState(() {
        appsLoading = false;
        wakeStatus = 'Could not load your apps: $e';
      });
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
  Widget _selectedAppsStrip(ColorScheme colors) {
    final chosen = installedApps
        .where((app) => selectedApps.contains(app.packageName))
        .toList();

    if (chosen.isEmpty) {
      return Text(
        'No apps selected yet.',
        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
      );
    }

    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 8, right: 8),
        itemCount: chosen.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final app = chosen[index];

          return SizedBox(
            width: 62,
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _appIcon(app, colors, size: 48),
                    Positioned(
                      right: -6,
                      top: -6,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            selectedApps.remove(app.packageName);
                          });
                          _saveSelection();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade700,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

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
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      // Stops battery saving from killing the listener in the background.
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      // NEW: Accessibility must be ON before the assistant starts.
      if (!await _ensureAccessibility()) return;

      await wakeWord.setAllowedApps(selectedApps);

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
    voice.dispose();
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

                const SizedBox(height: 14),

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

                const SizedBox(height: 20),

                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Choose your apps',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${selectedApps.length} selected',
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 4),
                Text(
                  'Voice Assistant will only open and control the apps you tick here.',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),

                const SizedBox(height: 10),

                _selectedAppsStrip(colors),

                const SizedBox(height: 12),

                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search apps',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: appSearch.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchController.clear();
                              FocusScope.of(context).unfocus();
                              setState(() {
                                appSearch = '';
                              });
                            },
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      appSearch = value;
                    });
                  },
                ),

                const SizedBox(height: 10),

                Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 280,
                    child: appsLoading
                        ? const Center(child: CircularProgressIndicator())
                        : _visibleApps.isEmpty
                        ? Center(
                            child: Text(
                              installedApps.isEmpty
                                  ? 'No apps found.'
                                  : 'No app matches "$appSearch".',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 22,
                              vertical: 5,
                            ),
                            itemCount: _visibleApps.length,
                            separatorBuilder: (_, _) =>
                                Divider(height: 1, color: Colors.grey.shade200),
                            itemBuilder: (context, index) {
                              final app = _visibleApps[index];
                              final isSelected = selectedApps.contains(
                                app.packageName,
                              );

                              return CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.trailing,
                                secondary: _appIcon(app, colors),
                                title: Text(
                                  app.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                value: isSelected,
                                activeColor: colors.primary,
                                onChanged: (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      selectedApps.add(app.packageName);
                                    } else {
                                      selectedApps.remove(app.packageName);
                                    }
                                  });

                                  _saveSelection();
                                },
                              );
                            },
                          ),
                  ),
                ),

                const SizedBox(height: 15),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.hearing),
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
                    icon: const Icon(Icons.arrow_forward),
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
                    icon: const Icon(Icons.help_outline),
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
