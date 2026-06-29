import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  const kBraodcastPort = 4000;
  const sampleRate = 44100;
  const channels = 1;

  final process = await Process.start('ffplay', [
    '-f',
    'f32le',
    '-ar',
    '$sampleRate',
    '-ac',
    '$channels',
    '-nodisp',
    '-autoexit',
    '-',
  ], mode: ProcessStartMode.detachedWithStdio);

  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kBraodcastPort);
  print('Listening UDP on 0.0.0.0:${socket.port}');
  final stream = socket
      .where((event) => event == RawSocketEvent.read)
      .where((event) => socket.receive() != null)
      .map((event) => socket.receive()!)
      .map((datagram) => _float32leToFloat32List(datagram.data));

  stream.listen((event) {
    final chunk = Float32List.fromList(event.map((e) => e.toDouble()).toList());
    print('this is a test: $chunk');
    process.stdin.add(chunk.buffer.asUint8List());
  });

  ProcessSignal.sigint.watch().listen((_) async {
    print('Stopping...');
    socket.close();
    exit(0);
  });
}

List<double> _float32leToFloat32List(Uint8List bytes) {
  final byteData = ByteData.sublistView(bytes);
  final sampleCount = bytes.length ~/ 4;
  final samples = List<double>.filled(sampleCount, 0);
  for (int i = 0; i < sampleCount; i++) {
    samples[i] = byteData.getFloat32(i * 4, Endian.little);
  }
  return samples;
}

void unawaited(Future<void> f) {}
