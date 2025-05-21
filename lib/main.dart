// main.dart dosyasında
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Author: Vahan Dağ
/// 05.21.2025

// Firebase veya kendi sunucunuz için URL
const String SERVER_URL = 'https://your-firebase-url.com/api/location';

// Notifications için sabitler
const String NOTIFICATION_CHANNEL_ID = 'my_foreground';
const String NOTIFICATION_CHANNEL_NAME = 'Foreground Service';
const int NOTIFICATION_ID = 888;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Servisi başlat
  await initializeService();

  runApp(MyApp());
}

// Bildirim kanalı oluştur
Future<void> initializeNotifications() async {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // Android'in varsayılan bildirim ikonunu kullan
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@android:drawable/ic_dialog_info');

  final InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // Bildirim kanalını açık bir şekilde oluştur
  if (Platform.isAndroid) {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      NOTIFICATION_CHANNEL_ID,
      NOTIFICATION_CHANNEL_NAME,
      importance: Importance.high,
      enableVibration: false,
      playSound: false,
    );

    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
  }
}

// Arkaplan servisini başlat
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // Notifications oluştur
  await initializeNotifications();

  // Android için servis yapılandırması
  await service.configure(
    androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: NOTIFICATION_CHANNEL_ID,
        initialNotificationTitle: 'Konum Takip Uygulaması',
        initialNotificationContent: 'Konum izleniyor...',
        foregroundServiceNotificationId: NOTIFICATION_ID,
        autoStartOnBoot: true),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// iOS için
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

// Servis başladığında çalışacak kod
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Eğer Android servisi ise bildirim göster
  if (service is AndroidServiceInstance) {
    // Başlangıçta servisi ön planda başlat ve bildirim ayarla
    service.setForegroundNotificationInfo(
      title: "Konum Takip Uygulaması",
      content: "Konum izleniyor...",
    );
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // 30 saniyede bir konum alıp gönder
  Timer.periodic(const Duration(seconds: 30), (timer) async {
    Position? position;

    try {
      // Konum izinlerini kontrol et
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          // İzin verilmediğinde bildirim güncelle
          if (service is AndroidServiceInstance) {
            service.setForegroundNotificationInfo(
              title: "Konum Takip Uygulaması",
              content: "Konum izni verilmedi!",
            );
          }
          return;
        }
      }

      // Konum al
      position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      // Cihaz bilgisi al
      final deviceInfo = DeviceInfoPlugin();
      String deviceId = "";

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? "";
      }

      // Bildirim güncelle
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "Konum Takip Çalışıyor",
          content: "Konum: ${position.latitude}, ${position.longitude}",
        );
      }

      // Konum verilerini sakla
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('latitude', position.latitude);
      await prefs.setDouble('longitude', position.longitude);
      await prefs.setString('lastUpdate', DateTime.now().toString());

      // Konum bilgisini sunucuya gönder
      try {
        await http.post(
          Uri.parse(SERVER_URL),
          body: {
            'latitude': position.latitude.toString(),
            'longitude': position.longitude.toString(),
            'deviceId': deviceId,
            'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
          },
        );
      } catch (e) {
        print("Sunucu hatası: $e");
      }

      // Servis durumunu bildir
      service.invoke(
        'update',
        {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': DateTime.now().toString(),
        },
      );
    } catch (e) {
      print(e);
    }
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _latitude = "Henüz alınmadı";
  String _longitude = "Henüz alınmadı";
  String _lastUpdate = "Henüz güncellenmedi";
  bool _isServiceRunning = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _loadServiceStatus();
    _loadLastLocation();
  }

  // İzinleri kontrol et
  Future<void> _checkPermissions() async {
    await Permission.location.request();
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
  }

  // Son konum bilgisini yükle
  Future<void> _loadLastLocation() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _latitude = prefs.getDouble('latitude')?.toString() ?? "Henüz alınmadı";
      _longitude = prefs.getDouble('longitude')?.toString() ?? "Henüz alınmadı";
      _lastUpdate = prefs.getString('lastUpdate') ?? "Henüz güncellenmedi";
    });
  }

  // Servis durumunu yükle
  Future<void> _loadServiceStatus() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    setState(() {
      _isServiceRunning = isRunning;
    });
  }

  // Servisi başlat/durdur
  Future<void> _toggleService() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke('stopService');
    } else {
      service.startService();
    }

    // Durum değişikliğinden sonra biraz bekle ve güncelle
    await Future.delayed(Duration(milliseconds: 500));
    _loadServiceStatus();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text('Konum Takip Uygulaması'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Servis Durumu: ${_isServiceRunning ? "Çalışıyor" : "Durdu"}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(height: 20),
              Text('Son Konum:', style: TextStyle(fontSize: 16)),
              Text('Enlem: $_latitude', style: TextStyle(fontSize: 14)),
              Text('Boylam: $_longitude', style: TextStyle(fontSize: 14)),
              Text('Son Güncelleme: $_lastUpdate', style: TextStyle(fontSize: 12)),
              SizedBox(height: 30),
              ElevatedButton(
                onPressed: _toggleService,
                child: Text(_isServiceRunning ? 'Servisi Durdur' : 'Servisi Başlat'),
              ),
              SizedBox(height: 10),
              ElevatedButton(
                onPressed: _loadLastLocation,
                child: Text('Konum Bilgisini Güncelle'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
