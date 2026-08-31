# Yam Mobile — Appel audio/vidéo WebRTC (Flutter)

Application mobile **Flutter** de **Yam**, une application d'appels audio et vidéo
en temps réel basée sur **WebRTC**, avec signalisation via **Reverb (WebSocket)**.

## Fonctionnalités

- Appels **audio** et **vidéo** en temps réel (WebRTC)
- Écran d'appel entrant avec sonnerie, vibration et notification push (FCM)
- Historique des appels (manqués / passés)
- Gestion des contacts
- Bascule caméra / micro / haut-parleur pendant l'appel
- Notifications push (Firebase Cloud Messaging) pour réveiller l'appareil

## Architecture

| Fichier | Rôle |
|---------|------|
| `lib/services/call_service.dart` | Logique WebRTC (PeerConnection, signalisation, caméra) |
| `lib/services/api_client.dart` | Client HTTP vers le backend Laravel |
| `lib/services/push_service.dart` | Notifications push FCM |
| `lib/services/runtime_config.dart` | Configuration runtime (Reverb/TURN) chargée depuis le backend |
| `lib/screens/in_call_screen.dart` | Écran d'appel (mode audio + mode vidéo) |
| `lib/screens/incoming_call_screen.dart` | Écran d'appel entrant |
| `lib/screens/contacts_screen.dart` | Liste des contacts |

## Configuration

La configuration runtime (Reverb, TURN) est chargée dynamiquement depuis le
backend via `GET /api/v1/config` — aucune clé secrète n'est codée en dur dans l'app.

Le fichier `android/app/google-services.json` contient la clé API Firebase
**publique** (nécessaire au fonctionnement de FCM). Il s'agit d'une clé publique
par conception, destinée à être embarquée dans l'app.

## Backend

Le backend Laravel associé est disponible dans le repo séparé
[`yam-api`](https://github.com/Daniel-the-one/yam-api).

## Démarrage

```bash
flutter pub get
flutter run
```

## Tests

```bash
flutter test
```
