// Smoke-test app for the fsd plugin.
//
// 1. Push a GGUF / safetensors checkpoint to the device, e.g.:
//    adb push sd_v1.5_lcm.gguf /sdcard/Download/
// 2. Run:  flutter run --release
// 3. Paste the absolute path into the "Model path" field, tap Load.
// 4. Type a prompt, tap Generate.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fsd/fsd.dart';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fsd example',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _engine = FsdEngine();
  // Default to the app-scoped external dir — no storage permission needed,
  // and reachable from adb without su:
  //   adb push model.gguf /sdcard/Android/data/com.tacita.fsd_example/files/
  final _modelCtrl = TextEditingController(
    text: Platform.isAndroid
        ? '/sdcard/Android/data/com.tacita.fsd_example/files/sd_v1.5_lcm.gguf'
        : '',
  );
  final _promptCtrl = TextEditingController(
    text: 'a watercolour painting of a fox in a forest, soft light',
  );

  String _status = 'idle';
  ImageGenStep? _lastStep;
  Uint8List? _png;
  StreamSubscription<ImageGenProgress>? _sub;
  bool _busy = false;

  @override
  void dispose() {
    _sub?.cancel();
    _engine.dispose();
    _modelCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _status = 'loading model…';
      _busy = true;
    });
    final stopwatch = Stopwatch()..start();
    try {
      await _engine.loadModel(modelPath: _modelCtrl.text.trim());
      setState(() => _status =
          'loaded in ${stopwatch.elapsedMilliseconds} ms · sd commit '
          '$nativeStableDiffusionCommit');
    } catch (e) {
      setState(() => _status = 'load error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _unload() async {
    await _engine.unloadModel();
    setState(() {
      _status = 'unloaded';
      _png = null;
      _lastStep = null;
    });
  }

  void _generate() {
    _sub?.cancel();
    setState(() {
      _status = 'generating…';
      _png = null;
      _lastStep = null;
      _busy = true;
    });
    final sw = Stopwatch()..start();
    final stream = _engine.generate(
      request: ImageGenRequest(
        prompt: _promptCtrl.text,
        width: 256,
        height: 256,
        steps: 4,
      ),
    );
    _sub = stream.listen((event) {
      switch (event) {
        case ImageGenStep(:final step, :final total):
          // ignore: avoid_print
          print('[fsd] step $step/$total at ${sw.elapsedMilliseconds} ms');
          setState(() => _lastStep = event);
        case ImageGenDone(:final pngBytes):
          // ignore: avoid_print
          print('[fsd] done in ${sw.elapsedMilliseconds} ms, '
              '${pngBytes.length} bytes');
          setState(() {
            _png = pngBytes;
            _status = 'done in ${sw.elapsedMilliseconds} ms '
                '(${pngBytes.length ~/ 1024} KiB)';
            _busy = false;
          });
        case ImageGenError(:final message):
          // ignore: avoid_print
          print('[fsd] error: $message');
          setState(() {
            _status = 'error: $message';
            _busy = false;
          });
      }
    });
  }

  void _cancel() {
    _engine.cancel();
    setState(() => _status = 'cancel requested…');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fsd example')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                labelText: 'Model path (absolute)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy || _engine.isReady ? null : _load,
                    child: const Text('Load'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: !_engine.isReady || _busy ? null : _unload,
                    child: const Text('Unload'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _promptCtrl,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                border: OutlineInputBorder(),
              ),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: !_engine.isReady || _busy ? null : _generate,
                    child: const Text('Generate (256×256, 4 LCM steps)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? _cancel : null,
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status, style: const TextStyle(fontFamily: 'monospace')),
                  if (_lastStep != null)
                    Text(
                      'step ${_lastStep!.step}/${_lastStep!.total}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_png != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(_png!, fit: BoxFit.contain),
              ),
          ],
        ),
      ),
    );
  }
}
