// Render production Persian screens with fictional local data, then frame
// them for the Bazaar listing. No app runtime, network, or microphone is used.
// Run: flutter test scripts/bazaar-assets/capture_test.dart
// Test-only setup is intentional; this capture test lives outside test/.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/home_widget/home_widget_service.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/locale/locale_service.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/core/theme/app_theme.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:tark/core/widget/tark_mark.dart';
import 'package:tark/feature/audio/data/system_audio_capture.dart';
import 'package:tark/feature/audio/domain/entity/audio_frame.dart';
import 'package:tark/feature/landing/presentation/manager/landing_cubit.dart';
import 'package:tark/feature/landing/presentation/page/landing_page.dart';
import 'package:tark/feature/onboarding/presentation/manager/onboarding_cubit.dart';
import 'package:tark/feature/onboarding/presentation/page/onboarding_page.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';
import 'package:tark/feature/settings/presentation/page/settings_page.dart';
import 'package:tark/feature/transfer/data/service/session_role_store_impl.dart';
import 'package:tark/feature/transfer/data/service/transfer_mode_store_impl.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/page/walkie_talkie_page.dart';

const _orange = Color(0xFFF5853F);
const _white = Color(0xFFE9EDF1);
final _output = Directory('build/bazaar-assets');

class _Gate implements LicenseGate {
  @override
  bool allows(PremiumFeature feature) => true;
  @override
  bool get canPurchase => false;
  @override
  Stream<void> get changes => const Stream.empty();
}

class _Widgets implements HomeWidgetService {
  @override
  Future<bool> canPin() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Landing extends Cubit<LandingState> implements LandingCubit {
  _Landing()
    : super(
        const LandingState(
          localIp: '192.168.49.1',
          myName: 'آرمان',
          isLoading: false,
          transferMode: TransferMode.wifi,
          pinnedMode: null,
        ),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Walkie extends Cubit<WalkieTalkieState> implements WalkieTalkieCubit {
  _Walkie()
    : super(
        WalkieTalkieState.initial().copyWith(
          localId: 'demo-local',
          myName: 'آرمان',
          myAvatarId: 3,
          isReady: true,
          ridingPreset: true,
          myRole: SessionRole.host,
          transferMode: TransferMode.hotspot,
          activeUsers: [
            ChannelUser(
              id: 'demo-sara',
              name: 'سارا',
              isTalking: true,
              avatarId: 4,
              lastSeen: DateTime.utc(2026, 10, 10),
            ),
            ChannelUser(
              id: 'demo-ali',
              name: 'علی',
              isTalking: false,
              avatarId: 14,
              lastSeen: DateTime.utc(2026, 10, 10),
            ),
          ],
        ),
      );
  @override
  Stream<String> get systemAudioMessages => const Stream.empty();
  @override
  Stream<double> get musicLevels => const Stream.empty();
  @override
  Stream<AudioFrame> get frames => const Stream.empty();
  @override
  Stream<AudioFrame> get receivedFrames => Stream.value(
    AudioFrame(
      rms: 0.22,
      samples: List.generate(
        512,
        (i) =>
            0.45 * math.sin(i * 0.16) * math.sin(i * 0.021) +
            0.12 * math.sin(i * 0.39),
      ),
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SavedRoom _room() {
  final now = DateTime.utc(2026, 10, 10);
  return SavedRoom(
    room: Room(
      id: const RoomId('0123456789abcdef0123456789abcdef'),
      name: 'همسفرها',
      createdAt: now,
      updatedAt: now,
      members: [
        for (final (i, name, avatar) in [
          (1, 'آرمان', 3),
          (2, 'سارا', 4),
          (3, 'علی', 14),
        ])
          RoomMember(
            id: RoomMemberId(i.toString().padLeft(24, '0')),
            displayName: name,
            avatarId: avatar,
            joinedAt: now,
          ),
      ],
    ),
    membership: RoomMembership(
      localMemberId: RoomMemberId('1'.padLeft(24, '0')),
      canManageInvites: true,
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<Uint8List> _save(
  WidgetTester tester,
  GlobalKey key,
  String path, {
  double ratio = 3,
}) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: ratio);
    final data = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    await File(path).writeAsBytes(data);
    return data;
  }))!;
}

void main() {
  setUpAll(() async {
    await _output.create(recursive: true);
    await Directory('${_output.path}/raw').create(recursive: true);
    for (final weight in ['Regular', 'Bold', 'ExtraBold', 'Black']) {
      await (FontLoader(
        'Vazirmatn',
      )..addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'))).load();
    }
    final configFile = File('.dart_tool/package_config.json');
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final flutter = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((package) => package['name'] == 'flutter');
    final sdkPackage = configFile.absolute.uri.resolve(
      '${flutter['rootUri']}/',
    );
    final iconBytes = await File.fromUri(
      sdkPackage.resolve(
        '../../bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ).readAsBytes();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(iconBytes)))).load();
  });

  testWidgets(
    'export six production screenshots and Persian marketing frames',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        SettingsKeys.userName: 'آرمان',
        SettingsKeys.avatarId: 3,
        SettingsKeys.appLocale: 'fa',
        SettingsKeys.appTheme: 'dark',
        SettingsKeys.usageTipsShown: true,
        SettingsKeys.ridingPreset: true,
      });
      final prefs = await SharedPreferences.getInstance();
      LocaleService.initialize(prefs);
      ThemeService.initialize(prefs);
      final settings = SettingsRepositoryImpl(prefs);
      final gate = _Gate();
      final modes = TransferModeStoreImpl(prefs, SessionRoleStoreImpl(), gate);
      await modes.initialize();
      GetIt.instance
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<LicenseGate>(gate)
        ..registerSingleton<HomeWidgetService>(_Widgets())
        ..registerSingleton<RoomRepository>(SharedPreferencesRoomRepository())
        ..registerFactory<LandingCubit>(_Landing.new)
        ..registerFactory<WalkieTalkieCubit>(_Walkie.new)
        ..registerFactory<OnboardingCubit>(
          () => OnboardingCubit(modes, settings),
        );
      PackageInfo.setMockInitialValues(
        appName: 'Tarkk',
        packageName: 'tark',
        version: '1.1.2',
        buildNumber: '34',
        buildSignature: 'preview',
      );
      SystemAudioCapture.debugIsAndroid = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('tark/system_audio'),
        (_) async => true,
      );
      addTearDown(() async {
        tester.view.reset();
        SystemAudioCapture.debugIsAndroid = null;
        await GetIt.instance.reset();
      });

      final scenes = <(String, String, String, String, Widget Function())>[
        (
          '01-offline',
          'گوشی‌ات را بی‌سیم کن',
          'بدون اینترنت',
          'برای سفر، مسیر و لحظه‌های کنار هم',
          LandingPage.buildPage,
        ),
        (
          '02-voice',
          'صدای هم را',
          'در مسیر بشنوید',
          'گفت‌وگوی زنده با همسفرها',
          WalkieTalkiePage.buildPage,
        ),
        (
          '03-rooms',
          'یک اتاق بساز؛',
          'همراه‌ها را جمع کن',
          'اعضای گروه، همیشه یک‌جا',
          () => SelectedRoomLobby(
            room: _room(),
            onStartRide: () {},
            onBack: () {},
            requiresPremium: false,
          ),
        ),
        (
          '04-connect',
          'هر جا هستید،',
          'به هم وصل شوید',
          'وای‌فای، هات‌اسپات یا بلوتوث',
          () => OnboardingPage.buildPage(initialStep: 4, initialName: 'آرمان'),
        ),
        (
          '05-riding',
          'آماده برای',
          'جاده و همسفرها',
          'حالت سواری و تنظیمات دلخواه',
          SettingsPage.buildPage,
        ),
        (
          '06-light',
          'روشن یا تاریک؛',
          'به سلیقهٔ تو',
          'رابط فارسی با دو ظاهر متفاوت',
          LandingPage.buildPage,
        ),
      ];
      for (var index = 0; index < scenes.length; index++) {
        final (name, first, second, subtitle, build) = scenes[index];
        if (index == 5) await ThemeService.setMode(AppThemeMode.light);
        tester.view.physicalSize = const Size(390, 780);
        tester.view.devicePixelRatio = 1;
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(name),
            locale: const Locale('fa'),
            theme: buildAppTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => RepaintBoundary(
              key: key,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
            ),
            home: build(),
          ),
        );
        await tester.runAsync(() async {
          final assets =
              [
                ...Directory('assets/avatars').listSync().whereType<File>(),
                ...Directory('assets/image').listSync().whereType<File>(),
              ].where(
                (file) =>
                    file.path.endsWith('.webp') || file.path.endsWith('.png'),
              );
          await Future.wait(
            assets.map(
              (file) => precacheImage(
                AssetImage(file.path.replaceAll('\\', '/')),
                key.currentContext!,
              ),
            ),
          );
        });
        await _frames(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '$name must render without layout errors',
        );
        final bytes = await _save(tester, key, '${_output.path}/raw/$name.png');
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        tester.view.physicalSize = const Size(540, 960);
        final boardKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey('board-$name'),
            theme: ThemeData(fontFamily: 'Vazirmatn'),
            home: RepaintBoundary(
              key: boardKey,
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: _Board(
                  bytes: bytes,
                  first: first,
                  second: second,
                  subtitle: subtitle,
                  index: index,
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => precacheImage(MemoryImage(bytes), boardKey.currentContext!),
        );
        await _frames(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '$name marketing frame must fit',
        );
        await _save(tester, boardKey, '${_output.path}/$name.png', ratio: 2);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );
}

class _Board extends StatelessWidget {
  const _Board({
    required this.bytes,
    required this.first,
    required this.second,
    required this.subtitle,
    required this.index,
  });
  final Uint8List bytes;
  final String first, second, subtitle;
  final int index;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF10161B),
    child: Stack(
      children: [
        Positioned.fill(child: CustomPaint(painter: _RadioLines())),
        Positioned(
          top: 25,
          right: 35,
          child: Row(
            children: [
              const TarkMark(size: 27, color: _orange),
              const SizedBox(width: 9),
              Text(
                'تَرک',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: _white,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 36,
          left: 35,
          child: Text(
            'بی‌سیمِ همراه',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA8AE)),
          ),
        ),
        Positioned(
          top: 85,
          left: 28,
          right: 28,
          child: Column(
            children: [
              Text(
                first,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 35,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                  color: _white,
                ),
              ),
              Text(
                second,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 35,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                  color: _orange,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: Color(0xFFA8B4BA),
                ),
              ),
            ],
          ),
        ),
        // An Android-style frame: rounded aluminium bezel, speaker and side keys.
        Positioned(
          top: 255,
          left: 444,
          child: Container(
            width: 3,
            height: 43,
            decoration: BoxDecoration(
              color: const Color(0xFF56616A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Positioned(
          top: 313,
          left: 444,
          child: Container(
            width: 3,
            height: 65,
            decoration: BoxDecoration(
              color: const Color(0xFF56616A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Positioned(
          top: 227,
          left: 95,
          width: 350,
          height: 703,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 15, 8, 20),
            decoration: BoxDecoration(
              color: const Color(0xFF030608),
              borderRadius: BorderRadius.circular(38),
              border: Border.all(color: const Color(0xFF606970), width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x88000000),
                  blurRadius: 28,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(27),
              child: Image.memory(
                bytes,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
        Positioned(
          top: 234,
          left: 249,
          child: Container(
            width: 42,
            height: 3,
            decoration: BoxDecoration(
              color: const Color(0xFF434B51),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        Positioned(
          top: 920,
          left: 235,
          child: Container(
            width: 70,
            height: 3,
            decoration: BoxDecoration(
              color: const Color(0xFF727A80),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        Positioned(
          top: 945,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              6,
              (i) => Container(
                width: i == index ? 18 : 4,
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i == index ? _orange : const Color(0xFF3A464E),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _RadioLines extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0xFF26333C);
    for (final radius in [220.0, 310.0, 400.0, 490.0]) {
      canvas.drawCircle(Offset(size.width / 2, 580), radius, paint);
    }
    paint.color = const Color(0xFF1D2931);
    canvas.drawLine(const Offset(35, 65), const Offset(505, 65), paint);
    for (var y = 250.0; y < 900; y += 35) {
      canvas.drawLine(Offset(35, y), Offset(41, y), paint);
      canvas.drawLine(Offset(499, y), Offset(505, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
