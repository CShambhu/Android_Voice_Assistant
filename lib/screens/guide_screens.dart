import 'package:flutter/material.dart';

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  static const List<({String title, String body})> _steps = [
    (
      title: 'Select all apps you want to control',
      body:
          'On the home screen, tick every app you want Voice Assistant to open '
          'and control. Only selected apps can be controlled. You can change '
          'the list any time.',
    ),
    (
      title: 'Allow the microphone',
      body:
          'When asked, tap "While using the app" or "Allow". Without the '
          'microphone the assistant cannot hear you.',
    ),
    (
      title: 'Turn on "Appear on top"',
      body:
          'Settings > Apps > Special app access > Display over other apps > '
          'Voice Assistant > turn ON. The app opens this screen for you. '
          'It lets the assistant open apps while another app is on screen.',
    ),
    (
      title: 'Turn on "Accessibility"',
      body:
          'Settings > Accessibility > Installed apps (or Downloaded apps) > '
          'Hello Boss Voice Controls > turn ON > Allow.\n'
          'This lets the assistant use Home and Back for you. The app opens '
          'this screen for you.',
    ),
    (
      title: 'Accessibility switch greyed out? (Android 13+)',
      body:
          'If you installed the app from an APK file, Android may block the '
          'switch. Settings > Apps > Voice Assistant > tap the ⋮ menu '
          '(top-right) > Allow restricted settings. Then repeat step 4.',
    ),
    (
      title: 'Keep the assistant alive in the background',
      body:
          'Allow notifications, and when asked to ignore battery optimisation '
          'choose "Allow". On Xiaomi, Oppo, Vivo, Realme, Samsung and similar '
          'phones, also enable "Autostart" and lock the app in Recent apps.',
    ),
    (
      title: 'Click "Get Started"',
      body:
          'Press Get Started. The voice assistant runs in the background and '
          'listens for your wake word.',
    ),
    (
      title: 'Speak your command',
      body:
          'Say the wake word, then your command, for example: "Open WhatsApp". '
          'Speak clearly and close to the phone. Commands only work on the '
          'apps you selected in step 1.',
    ),
    (
      title: 'Choose your language',
      body:
          'Pick English, Nepali or Hindi on the home screen. The language '
          'must be installed in your phone\'s speech recognition settings.',
    ),
    (
      title: 'Stop the assistant',
      body:
          'Open the app and press "Turn off microphone". To remove its '
          'control completely, turn off Accessibility in Settings.',
    ),
    (
      title: 'Troubleshooting',
      body:
          '• Not responding: check microphone permission and your speech '
          'recognition service.\n'
          '• Stops after a while: redo step 6.\n'
          '• An app is not opening: make sure it is ticked in step 1.\n'
          '• Accessibility turned itself off: this can happen after an update '
          'or a force-stop. Turn it on again.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F5FC),
      appBar: AppBar(
        title: const Text('How to use the app'),
        backgroundColor: const Color(0xFFF7F5FC),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: _steps.length,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          final step = _steps[index];

          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        step.body,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: Colors.grey.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
