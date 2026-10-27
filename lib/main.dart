import 'dart:async';

import 'package:android_voice_assistant/widget/voice_area.dart';
import 'package:android_voice_assistant/services/wake_word_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

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

      final apps = await _getInstalledApps();

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
      title: 'Hello Boss',
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

class _SetupScreenState extends State<SetupScreen> {
  final VoiceController voice = VoiceController();
  final WakeWordBridge wakeWord = WakeWordBridge();

  StreamSubscription<Map<String, dynamic>>? wakeSubscription;

  String wakeStatus = 'Wake word is off';
  String lastCommand = '';
  int wakeWordCount = 0;

  bool backgroundListening = false;
  bool wakeBusy = false;

  String selectedLanguage = 'English';
  bool rememberMe = true;

  final List<AppItem> apps = [
    AppItem('Phone', Icons.phone, Colors.green),
    AppItem('Messages', Icons.message, Colors.blue),
    AppItem('WhatsApp', Icons.chat, Colors.green),
    AppItem('Gmail', Icons.mail, Colors.red),
    AppItem('Settings', Icons.settings, Colors.blueGrey),
    AppItem('Calendar', Icons.calendar_month, Colors.deepOrange),
    AppItem('Music', Icons.music_note, Colors.purple),
    AppItem('Contacts', Icons.contacts, Colors.teal),
  ];

  final Set<String> selectedApps = {'Phone', 'Messages', 'WhatsApp'};

  @override
  void initState() {
    super.initState();

    wakeSubscription = wakeWord.events.listen(
      (event) {
        if (!mounted) return;

        final type = event['type'] as String? ?? '';
        final value = event['value'] as String? ?? '';

        setState(() {
          switch (type) {
            case 'status':
              wakeStatus = value;
              backgroundListening = value == 'listening' || value == 'command';

              if (value == 'stopped') {
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
              wakeStatus = value;
              backgroundListening = false;
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
    wakeSubscription?.cancel();
    unawaited(wakeWord.stop());
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
                      const SizedBox(height: 12),
                      Text(
                        'Hello Boss',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
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

                const SizedBox(height: 24),

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
                  'Select the apps Hello Boss can help you with.',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),

                const SizedBox(height: 10),

                Container(
                  height: 150,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 5,
                    ),
                    itemCount: apps.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: Colors.grey.shade200),
                    itemBuilder: (context, index) {
                      final app = apps[index];
                      final isSelected = selectedApps.contains(app.name);

                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.trailing,
                        secondary: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: app.color.withAlpha(25),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(app.icon, color: app.color, size: 24),
                        ),
                        title: Text(
                          app.name,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        value: isSelected,
                        activeColor: colors.primary,
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              selectedApps.add(app.name);
                            } else {
                              selectedApps.remove(app.name);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                // VoiceArea(voice: voice, colors: colors),
                const SizedBox(height: 16),

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

                        const SizedBox(height: 14),

                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: wakeBusy || backgroundListening
                                    ? null
                                    : () async {
                                        setState(() {
                                          wakeBusy = true;
                                        });

                                        try {
                                          final status = await Permission
                                              .microphone
                                              .request();

                                          if (!status.isGranted) {
                                            if (!mounted) return;

                                            setState(() {
                                              wakeStatus =
                                                  status.isPermanentlyDenied
                                                  ? 'Microphone permission is permanently denied.'
                                                  : 'Microphone permission is required.';
                                            });

                                            if (status.isPermanentlyDenied) {
                                              await openAppSettings();
                                            }
                                            return;
                                          }

                                          await wakeWord.setLanguage(
                                            selectedLanguage,
                                          );
                                          await wakeWord.start();

                                          if (!mounted) return;

                                          setState(() {
                                            wakeStatus = 'Starting listener...';
                                          });
                                        } on PlatformException catch (e) {
                                          if (!mounted) return;

                                          setState(() {
                                            wakeStatus =
                                                e.message ??
                                                'Could not start listening';
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
                                      },
                                icon: const Icon(Icons.mic),
                                label: const Text('Start listening'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red.shade700,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: wakeBusy
                                    ? null
                                    : () async {
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
                                            wakeStatus =
                                                'Microphone turned off';
                                          });
                                        } catch (e) {
                                          if (!mounted) return;

                                          setState(() {
                                            wakeStatus =
                                                'Could not turn off microphone: $e';
                                          });
                                        } finally {
                                          if (mounted) {
                                            setState(() {
                                              wakeBusy = false;
                                            });
                                          }
                                        }
                                      },
                                icon: const Icon(Icons.mic_off),
                                label: const Text('Turn off microphone'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 8),

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

                const SizedBox(height: 8),

                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: () {
                      if (selectedApps.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Please select at least one app.'),
                          ),
                        );
                        return;
                      }

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Language: $selectedLanguage | '
                            'Apps selected: ${selectedApps.length} | '
                            'Remember me: '
                            '${rememberMe ? "Yes" : "No"}',
                          ),
                        ),
                      );
                    },
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

                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppItem {
  final String name;
  final IconData icon;
  final Color color;

  const AppItem(this.name, this.icon, this.color);
}
