// import 'dart:async';
// import 'dart:convert';

// import 'package:flutter/material.dart';
// import 'package:vosk_flutter/vosk_flutter.dart';

// /// Offline speech-to-text using Vosk. No beep, no internet, no restart loop.
// class VoiceController extends ChangeNotifier {
//   final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
//   final ModelLoader _loader = ModelLoader();
//   final TextEditingController textController = TextEditingController();

//   /// Language name (as used in the dropdown) -> bundled model asset.
//   /// Nepali has no Vosk model, so it is intentionally missing.
//   static const Map<String, String> _modelAssets = {
//     'English': 'assets/models/vosk-model-small-en-us-0.15.zip',
//     'Hindi': 'assets/models/vosk-model-small-hi-0.22.zip',
//   };

//   Model? _model;
//   Recognizer? _recognizer;
//   SpeechService? _service;
//   StreamSubscription<String>? _partialSub;
//   StreamSubscription<String>? _resultSub;

//   String _language = 'English';
//   String _committed = '';

//   bool micOn = false;
//   bool loading = false;
//   String error = '';

//   Future<bool> _prepare() async {
//     final asset = _modelAssets[_language];
//     if (asset == null) {
//       error =
//           '$_language is not available offline yet. '
//           'Please choose English or Hindi.';
//       notifyListeners();
//       return false;
//     }

//     loading = true;
//     notifyListeners();
//     try {
//       final path = await _loader.loadFromAssets(asset);
//       _model = await _vosk.createModel(path);
//       _recognizer = await _vosk.createRecognizer(
//         model: _model!,
//         sampleRate: 16000,
//       );
//       _service = await _vosk.initSpeechService(_recognizer!);
//       _partialSub = _service!.onPartial().listen(_onPartial);
//       _resultSub = _service!.onResult().listen(_onResult);
//       return true;
//     } catch (e) {
//       error = 'Could not load the speech model: $e';
//       return false;
//     } finally {
//       loading = false;
//       notifyListeners();
//     }
//   }

//   Future<void> setMic(bool on) async {
//     if (on) {
//       error = '';
//       if (_service == null) {
//         final ok = await _prepare();
//         if (!ok) {
//           micOn = false;
//           notifyListeners();
//           return;
//         }
//       }
//       try {
//         _committed = textController.text.trim();
//         await _service!.start();
//         micOn = true;
//       } on MicrophoneAccessDeniedException {
//         micOn = false;
//         error =
//             'Microphone permission was denied. '
//             'Allow it in your phone settings and try again.';
//       } catch (e) {
//         micOn = false;
//         error = 'Could not start the microphone: $e';
//       }
//       notifyListeners();
//     } else {
//       micOn = false;
//       await _service?.stop();
//       notifyListeners();
//     }
//   }

//   /// Called when the language dropdown changes.
//   Future<void> setLanguage(String language) async {
//     if (language == _language) return;
//     _language = language;
//     error = '';

//     final wasOn = micOn;
//     await _teardown();
//     micOn = false;
//     notifyListeners();

//     if (!_modelAssets.containsKey(language)) {
//       error =
//           '$language is not available offline yet. '
//           'Please choose English or Hindi.';
//       notifyListeners();
//       return;
//     }
//     if (wasOn) await setMic(true);
//   }

//   Future<void> _teardown() async {
//     await _partialSub?.cancel();
//     await _resultSub?.cancel();
//     _partialSub = null;
//     _resultSub = null;
//     try {
//       await _service?.stop();
//       await _service?.dispose();
//     } catch (_) {}
//     _service = null;
//     _recognizer = null;
//     _model = null;
//   }

//   void _onPartial(String json) {
//     final partial = (jsonDecode(json)['partial'] as String? ?? '').trim();
//     if (partial.isEmpty) return;
//     _setText(_join(_committed, partial));
//   }

//   void _onResult(String json) {
//     final text = (jsonDecode(json)['text'] as String? ?? '').trim();
//     if (text.isEmpty) return;
//     _committed = _join(_committed, text);
//     _setText(_committed);
//   }

//   String _join(String a, String b) => a.isEmpty ? b : '$a $b';

//   void _setText(String text) {
//     textController.value = TextEditingValue(
//       text: text,
//       selection: TextSelection.collapsed(offset: text.length),
//     );
//   }

//   void clear() {
//     textController.clear();
//     _committed = '';
//   }

//   @override
//   void dispose() {
//     _partialSub?.cancel();
//     _resultSub?.cancel();
//     _service?.dispose();
//     textController.dispose();
//     super.dispose();
//   }
// }
