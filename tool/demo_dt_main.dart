// Point d'entree de RENDU (outil de QA, pas livre avec l'application).
//
// Il monte directement l'ecran DT avec la session en mode demo offroad, pour
// obtenir une capture du scenario sans passer par le splash (5 taps) ni par
// l'ecran de connexion (choix du profil + identifiants valides par la base).
//
// Lancement :
//   flutter run -d chrome -t tool/demo_dt_main.dart
// ou, apres `flutter build web -t tool/demo_dt_main.dart`, en servant build/web.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'package:ore_tracking/screens/dt_screen.dart';
import 'package:ore_tracking/state/session.dart';
import 'package:ore_tracking/theme/app_theme.dart';

const Size _kTailleReference = Size(1120, 720);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
  } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const _DemoApp());
}

class _DemoApp extends StatefulWidget {
  const _DemoApp();

  @override
  State<_DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<_DemoApp> {
  final Session _session = Session();
  bool _pret = false;

  @override
  void initState() {
    super.initState();
    // Ouvre l'audio pendant le premier geste utilisateur sur l'ecran DT,
    // avant que le GPS simule declenche l'alerte sonore.
    // Mode demo offroad : parcours fictif + GPS simule qui sort de route.
    _session.ouvrirBase(demoOffroad: true).then((_) {
      if (mounted) setState(() => _pret = true);
    });
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: _kTailleReference,
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) => MaterialApp(
        title: 'ORE Tracking - demo DT',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: _pret
            ? DtScreen(session: _session)
            : const Scaffold(
                backgroundColor: AppColors.paper,
                body: Center(child: CircularProgressIndicator()),
              ),
      ),
    );
  }
}
