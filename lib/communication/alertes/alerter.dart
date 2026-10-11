import 'dart:async';
// Necessaire pour convertir les JSArray de package:web (getVoices())
// en List Dart via .toDart : sans cet import, la compilation web echoue.
import 'dart:js_interop';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:web/web.dart' as web;
import 'package:vibration/vibration.dart';

// dart:io n'existe pas sur le web : import conditionnel, seules les
// references arentes par kIsWeb y sont evaluees.
import 'io_stub.dart'
    if (dart.library.io) 'dart:io' show Platform;

/// Canal d'alerte sonore et vibratoire (choix terrain : signal a chaque
/// mesure GPS tant que le DT reste hors du parcours).
///
/// Interface injectable comme [FournisseurPosition] : les tests branchent
/// [AlerteFactice] et comptent les declenchements au lieu d'attendre un
/// materiel qui vibre.
abstract class AlerteMetier {
  /// Joue un bip court + une vibration + la voix off du message d'alerte.
  /// Ne leve jamais : un capteur absent ou une plateforme sans audio
  /// n'arrete pas l'application.
  void jouer();

  /// Annonce le [message] d'alerte par la synthese vocale (voix off).
  /// Utilise aussi pour annoncer la sortie/retour sur parcours.
  Future<void> dire(String message) async {}

  /// Deverrouille l'audio du navigateur web (autoplay policy). No-op hors
  /// web ; a appeler sur le premier tap utilisateur.
  void deverrouillerAudioWeb() {}

  /// Arrête le rappel vocal en boucle lorsqu'une alerte prend fin.
  void arreterRappelVocal() {}

  /// Libere les ressources systeme (lecteur audio). Vide par defaut.
  void fermer() {}
}

/// Compteur d'appels, pour les tests et le banc.
class AlerteFactice implements AlerteMetier {
  int appels = 0;

  /// Dernier message passe a [dire] (verifie dans les tests).
  String? dernierMessage;
  @override
  void jouer() => appels++;
  @override
  Future<void> dire(String message) async => dernierMessage = message;
  @override
  void deverrouillerAudioWeb() {}
  @override
  void arreterRappelVocal() {}
  @override
  void fermer() {}
}

/// Implementation systeme : vibration (`vibration`) + bip WAV embarque
/// (`audioplayers`), avec repli silencieux partout ou la plateforme ne
/// supporte pas l'un des deux (Windows sans vibreur, tests sans audio).
class AlerteSysteme implements AlerteMetier {
  AlerteSysteme({this.cheminBip = 'sons/alerte.wav'});

  /// Fichier WAV joue a chaque declenchemet (asset du package).
  final String cheminBip;
  AudioPlayer? _lecteur;

  /// Synthese vocale (voix off). Creee paresseusement : flutter_tts peut
  /// lever des que l'on touche l'instance sur une plateforme sans moteur TTS.
  FlutterTts? _tts;

  /// Une annonce d'alerte est répétée à cadence fixe avec le bip.
  String? _dernierTexte;
  DateTime _dernierDire = DateTime(2000);
  Timer? _rappelAlerte;
  bool _alerteEnCours = false;
  web.AudioContext? _contexteAudioWeb;
  String? _messageWebEnAttente;

  /// Audio du navigateur : Edge/Chrome demandent un geste utilisateur.
  bool _audioDebloqueWeb = false;
  /// Une seule initialisation du moteur TTS natif, partagee entre appels.
  Future<void>? _initTts;
  /// Derniere erreur TTS, journalisee pour diagnostic (au lieu d'etre avalee).
  String? derniereErreur;

  /// Deverrouille l'audio du navigateur. A appeler sur le premier tap de
  /// l'utilisateur (GestureRecognizer / onTapDown de l'ecran d'accueil).
  @override
  void deverrouillerAudioWeb() {
    if (!kIsWeb || _audioDebloqueWeb) return;
    try {
      final web.SpeechSynthesis synth = web.window.speechSynthesis;
      // IMPORTANT : forcer le chargement des voix AVANT le premier speak.
      // Sans cet appel, Chrome/Edge renvoient une liste vide au premier
      // passage et le speak suivant est rejete.
      synth.getVoices();
      // Deverrouille la synthese vocale avec une utterance silencieuse.
      final web.SpeechSynthesisUtterance u =
          web.SpeechSynthesisUtterance('desactivation');
      u.volume = 0.0;
      u.rate = 1.0;
      u.lang = 'fr-FR';
      synth.speak(u);
      synth.resume();

      // L'alerte est declenchee ensuite par le GPS, donc hors geste utilisateur.
      // Creer/demarrer le contexte durant ce geste autorise les bips suivants.
      final web.AudioContext contexte =
          _contexteAudioWeb ??= web.AudioContext();
      contexte.resume();
      final web.OscillatorNode oscillateur = contexte.createOscillator();
      final web.GainNode volume = contexte.createGain();
      volume.gain.value = 0.0;
      oscillateur.connect(volume);
      volume.connect(contexte.destination);
      oscillateur.start();
      oscillateur.stop(contexte.currentTime + 0.01);
      _audioDebloqueWeb = true;
      debugPrint('[Alerter] audio web deverrouille');

      // Une alerte peut arriver avant le premier geste et etre bloquee par
      // le navigateur. Rejouer le message apres le deverrouillage ; le bip
      // demarrera au meme instant que la voix dans dire().
      final String? message = _messageWebEnAttente;
      _messageWebEnAttente = null;
      if (message != null) {
        _dernierTexte = null;
        unawaited(dire(message));
      }
    } catch (e) {
      derniereErreur = 'deverrouillerAudioWeb: $e';
      debugPrint('[Alerter] echec deverrouillage web: $e');
    }
  }

  @override
  void jouer() {
    _vibrer();
    _bip();
  }

  @override
  Future<void> dire(String message) async {
    // Bip déclenché ici pour qu'il démarre au même instant que la voix.
    // jouer() continue d'émettre les bips périodiques au rythme GPS.
    // L'alerte GPS peut preceder le premier tap requis par Edge/Chrome.
    // Memoriser alors le message pour le prononcer juste apres le geste.
    final bool messageAlerte = _estMessageAlerte(message);
    if (kIsWeb && !_audioDebloqueWeb) {
      _messageWebEnAttente = message;
      if (messageAlerte) _alerteEnCours = true;
      debugPrint('[Alerter] voix en attente du geste utilisateur');
      return;
    }


    final DateTime maintenant = DateTime.now();
    if (!messageAlerte &&
        message == _dernierTexte &&
        maintenant.difference(_dernierDire) < const Duration(seconds: 25)) {
      return;
    }
    _dernierTexte = message;
    _dernierDire = maintenant;

    if (messageAlerte) {
      _alerteEnCours = true;
      _rappelAlerte?.cancel();
    } else {
      arreterRappelVocal();
    }

    // Bip au départ seulement pour un message d'alerte; les rappels le
    // rejouent au même moment que la voix toutes les 2 secondes.
    if (messageAlerte) {
      if (kIsWeb) {
        if (_audioDebloqueWeb) _bipWeb();
      } else {
        _bip();
      }
    }

    try {
      if (kIsWeb) {
        // Web : utiliser la Web Speech API et les voix disponibles dans Edge.
        await _direWeb(message);
        return;
      }
      final FlutterTts tts = _tts ??= FlutterTts();
      // Initialisation UNE SEULE FOIS, et attendue : appeler setLanguage
      // juste apres la creation de FlutterTts peut tomber avant que le
      // moteur natif soit pret (Android surtout) et l'erreur etait avalee.
      _initTts ??= _initialiserTts(tts);
      await _initTts;

      // Voix francaise sur TOUTES les plateformes (le message est en
      // francais partout). Sur Windows, si fr-FR n'existe pas, on retombe
      // proprement sur la voix par defaut du systeme.
      try {
        await tts.setLanguage('fr-FR');
      } catch (e) {
        debugPrint('[Alerter] fr-FR indisponible, voix par defaut: $e');
      }
      await tts.setSpeechRate(0.45);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);
      // awaitResult: true => on attend la fin reelle de la lecture.
      await tts.speak(message);
      if (messageAlerte && _alerteEnCours) _programmerRappel(message);
    } catch (e) {
      derniereErreur = 'dire: $e';
      debugPrint('[Alerter] echec TTS natif: $e');
    }
  }

  void _programmerRappel(String message) {
    _rappelAlerte?.cancel();
    _rappelAlerte = Timer(const Duration(seconds: 2), () {
      if (_alerteEnCours) _rappeler(message);
    });
  }

  void _rappeler(String message) {
    if (kIsWeb) {
      // Sur Edge, une nouvelle utterance pendant la lecture est ignorée;
      // l'intervalle de 2 s laisse le temps à la phrase de finir.
      unawaited(_direWeb(message));
      _bipWeb();
    } else {
      _bip();
      unawaited(_tts?.speak(message) ?? Future<dynamic>.value());
    }
  }

  bool _estMessageAlerte(String message) {
    final String texte = message.toLowerCase();
    return texte.contains('sortie de route') || texte.contains('hors parcours');
  }

  /// Arrête la répétition du bip et de la phrase d'alerte au retour au calme.
  @override
  void arreterRappelVocal() {
    _alerteEnCours = false;
    _rappelAlerte?.cancel();
    _rappelAlerte = null;
    _messageWebEnAttente = null;
    try {
      _lecteur?.stop();
    } catch (_) {}
    if (kIsWeb) {
      try {
        web.window.speechSynthesis.cancel();
      } catch (_) {}
    } else {
      try {
        _tts?.stop();
      } catch (_) {}
    }
  }

  /// Prepare le moteur TTS natif : attend l'initialisation effective et
  /// choisit une voix francaise si la plateforme en expose une.
  Future<void> _initialiserTts(FlutterTts tts) async {
    try {
      await tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('[Alerter] awaitSpeakCompletion indisponible: $e');
    }
    try {
      final dynamic langues = await tts.getLanguages;
      if (langues is List) {
        final bool aFr = langues.any(
          (dynamic l) => l.toString().toLowerCase().startsWith('fr'),
        );
        if (aFr) {
          await tts.setLanguage('fr-FR');
        } else {
          debugPrint('[Alerter] aucune voix fr sur la plateforme');
        }
      }
    } catch (e) {
      debugPrint('[Alerter] getLanguages indisponible: $e');
    }
  }

  /// Voix off sur le web, par la Web Speech API du navigateur.
  /// Attend le chargement asynchrone des voix avant de choisir la voix
  /// francaise installee (sur Edge, Charline fr-BE est disponible).
  Future<void> _direWeb(String message) async {
    try {
      final web.SpeechSynthesis synth = web.window.speechSynthesis;

      // 1) Le moteur peut etre en pause apres une longue inactivite
      //    (policy Chrome "speechSynthesis paused after 15s").
      synth.resume();

      // 2) Charger les voix AVANT de choisir : getVoices() vides au
      //    premier appel est la cause n1 de silence sur Chrome/Edge.
      web.SpeechSynthesisVoice? voix = _choisirVoixWeb(synth);
      for (int i = 0; voix == null && i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        voix = _choisirVoixWeb(synth);
      }

      // 3) Construire l'utterance sans annuler une phrase d'alerte encore en cours.
      final web.SpeechSynthesisUtterance u =
          web.SpeechSynthesisUtterance(message);
      if (voix != null) {
        u.voice = voix;
        u.lang = voix.lang;
      } else {
        u.lang = 'fr-FR';
      }
      u.rate = 0.9;
      u.pitch = 1.0;
      u.volume = 1.0;

      // N'annule que la phrase precedente, pas l'alerte courante si un
      // rappel arrive avant que le moteur TTS ait fini de parler.
      if (!synth.speaking) synth.cancel();
      // Laisser le temps au moteur de terminer la phrase précédente.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      synth.speak(u);
      debugPrint('[Alerter] speak web: "$message" voix=${voix?.name ?? "defaut"}');
      derniereErreur = null;
      if (_estMessageAlerte(message) && _alerteEnCours) {
        _programmerRappel(message);
      }
    } catch (e) {
      derniereErreur = '_direWeb: $e';
      debugPrint('[Alerter] echec TTS web: $e');
    }
  }

  /// Privilegie Charline (fr-BE), puis une voix fr-FR, puis toute voix
  /// francaise. Repli ensuite sur l'anglais ou la premiere voix disponible.
  web.SpeechSynthesisVoice? _choisirVoixWeb(web.SpeechSynthesis synth) {
    // getVoices() renvoie un JSArray<SpeechSynthesisVoice> SYNCHRONE
    // (pas une Future). L'ancien cast `as dynamic` + .toDart ne produisait
    // pas une List Dart exploitable -> liste vide -> aucune voix choisie.
    final List<web.SpeechSynthesisVoice> liste =
        synth.getVoices().toDart;
    if (liste.isEmpty) return null;

    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.name.toLowerCase().contains('charline') &&
          v.lang.toLowerCase().startsWith('fr')) {
        return v;
      }
    }
    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.lang.toLowerCase() == 'fr-fr') return v;
    }
    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.lang.toLowerCase().startsWith('fr')) return v;
    }
    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.lang.toLowerCase().startsWith('en')) return v;
    }
    return liste.first;
  }

  void _vibrer() {
    // Le plugin vibration n'a pas d'implementation web. Le bip et la voix
    // restent actifs dans le navigateur, sans tenter l'appel platform channel.
    if (kIsWeb) return;
    // try/catch systematique : vibration n'est pas implemente sur toutes les
    // plateformes, et l'alerte doit rester un bip meme sans vibreur.
    try {
      Vibration.vibrate(duration: 350);
    } catch (_) {
      try {
        // Repli : retour haptique du framework (aucune permission requise).
        HapticFeedback.vibrate();
      } catch (_) {}
    }
  }

  void _bip() {
    // try/catch partout : y compris l'acces a [Platform], indisponible sur
    // certaines cibles — `jouer()` ne doit jamais lever.
    try {
      // Le WAV n'existe pas dans les assets : generer le bip via Web Audio.
      // Si le navigateur n'est pas encore autorise, garder le bip en attente.
      if (kIsWeb) {
        if (_audioDebloqueWeb) _bipWeb();
        return;
      }
      if (!Platform.isAndroid &&
          !Platform.isIOS &&
          !Platform.isWindows) {
        return;
      }
      final AudioPlayer lecteur = _lecteur ??= AudioPlayer();
      // BytesSource : lecture des octets de l'asset via rootBundle puis
      // decodage direct. Plus fiable qu'AssetSource sur Windows, ou le
      // chemin d'asset a change silencieusement selon les versions.
      rootBundle.load('assets/$cheminBip').then((ByteData donnees) {
        lecteur.stop().then((void _) {
          lecteur
              .play(BytesSource(donnees.buffer.asUint8List()))
              .catchError((Object e) => debugPrint('[Alerte] bip KO: $e'));
        });
      }, onError: (Object e) {
        // Repli : AssetSource classique si rootBundle echoue.
        debugPrint('[Alerte] asset KO ($e), repli AssetSource');
        lecteur.play(AssetSource(cheminBip)).catchError((Object e2) {
          debugPrint('[Alerte] bip repli KO: $e2');
        });
      });
    } catch (e) {
      debugPrint('[Alerte] bip exception: $e');
    }
  }

  void _bipWeb() {
    try {
      final web.AudioContext contexte =
          _contexteAudioWeb ??= web.AudioContext();
      contexte.resume();
      final web.OscillatorNode oscillateur = contexte.createOscillator();
      final web.GainNode volume = contexte.createGain();
      oscillateur.type = 'sine';
      oscillateur.frequency.value = 880;
      volume.gain.setValueAtTime(0.0001, contexte.currentTime);
      volume.gain.exponentialRampToValueAtTime(
        0.35,
        contexte.currentTime + 0.015,
      );
      volume.gain.exponentialRampToValueAtTime(
        0.0001,
        contexte.currentTime + 0.22,
      );
      oscillateur.connect(volume);
      volume.connect(contexte.destination);
      oscillateur.start();
      oscillateur.stop(contexte.currentTime + 0.23);
    } catch (e) {
      derniereErreur = '_bipWeb: $e';
      debugPrint('[Alerte] bip web KO: $e');
    }
  }

  @override
  void fermer() {
    arreterRappelVocal();
    _lecteur?.dispose();
    _lecteur = null;
    try {
      _tts?.stop();
    } catch (_) {}
    _tts = null;
    if (kIsWeb) {
      try {
        web.window.speechSynthesis.cancel();
      } catch (_) {}
      try {
        _contexteAudioWeb?.close();
      } catch (_) {}
      _contexteAudioWeb = null;
    }
  }
}
