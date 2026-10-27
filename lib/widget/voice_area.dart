import 'package:flutter/material.dart';
import '../main.dart';

class VoiceArea extends StatelessWidget {
  final VoiceController voice;
  final ColorScheme colors;

  const VoiceArea({super.key, required this.voice, required this.colors});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Voice typing',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),

              // Microphone ON/OFF toggle.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: voice.loading
                      ? null
                      : () => voice.setMic(!voice.micOn),
                  icon: Icon(voice.micOn ? Icons.mic : Icons.mic_off),
                  label: Text(
                    voice.loading
                        ? 'Please wait...'
                        : voice.micOn
                        ? 'Turn Microphone OFF'
                        : 'Turn Microphone ON',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: voice.micOn ? Colors.red : colors.primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),

              if (voice.micOn) ...[
                const SizedBox(height: 8),
                const Row(
                  children: [
                    Icon(Icons.circle, color: Colors.red, size: 10),
                    SizedBox(width: 8),
                    Text('Listening...'),
                  ],
                ),
              ],

              if (voice.loading) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],

              const SizedBox(height: 12),

              // Live recognized text.
              TextField(
                controller: voice.textController,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: 'Your recognized speech appears here...',
                  filled: true,
                  fillColor: const Color(0xFFF7F5FC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    tooltip: 'Clear text',
                    icon: const Icon(Icons.clear),
                    onPressed: voice.clear,
                  ),
                ),
              ),

              if (voice.error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  voice.error,
                  style: TextStyle(color: colors.error, fontSize: 13),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
