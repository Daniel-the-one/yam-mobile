# SYNCHRONISATION WEB ↔ MOBILE — Yam

> **Date :** 7 septembre 2026
> **Objectif :** Aligner le comportement du client **mobile (Flutter)** sur celui du
> **web (JS)** après les corrections de bugs récentes sur le web.
>
> **Référence web corrigée :** `web/js/spa-calls.js`, `web/sw.js`, `web/js/spa-core.js`
> **Référence mobile :** `lib/services/call_service.dart`, `lib/services/push_service.dart`

---

## ⚠️ RÉSUMÉ EXÉCUTIF

Le web a été corrigé pour 3 bugs (ringback, appel coupé au décrochage, notifications
en arrière-plan) **plus** une revue de code qui a durci plusieurs comportements.
Le mobile n'a **pas** reçu ces corrections. **7 écarts** doivent être alignés,
dont **2 critiques** (délai de grâce, retry du bye) et **1 haute** (CallKit lit le
mauvais champ média).

---

## 🔴 ÉCARTS CRITIQUES (à corriger en priorité)

### 1. Délai de grâce "disconnected" — 1,5 s (mobile) vs 5 s (web)

**Web** (`spa-calls.js`) : délai de grâce de **5000 ms** sur l'état `disconnected`,
avec timer annulable (`disconnectGraceTimeout`) nettoyé dans `onCallEstablished`
et `teardown`.

**Mobile** (`call_service.dart:492`) : **1500 ms**, non annulable.

**Impact :** pendant une bascule Wi-Fi → 4G ou une coupure transitoire, un appel
vidéo valide est coupé à tort sur mobile (exactement le bug corrigé sur le web).

**Correction :**
```dart
// call_service.dart, dans onConnectionState (état Disconnected)
// Passer de 1500 ms à 5000 ms, et rendre le timer annulable.
Timer? _disconnectGraceTimer;

// dans onConnectionState Disconnected :
_disconnectGraceTimer?.cancel();
final captured = pc;
_disconnectGraceTimer = Timer(const Duration(milliseconds: 5000), () {
  if (identical(_pc, captured) &&
      captured.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
    unawaited(teardown());
  }
});

// annuler dans teardown() et quand l'appel se rétablit (connected) :
_disconnectGraceTimer?.cancel();
```

---

### 2. Retry du signal "bye" — aucun (mobile) vs 3 retries (web)

**Web** (`spa-calls.js`) : `sendSignal("bye")` retente jusqu'à **3 fois** avec
backoff (500 ms × tentative) si le serveur est injoignable au raccrochage.

**Mobile** (`call_service.dart` + `api_client.dart`) : **une seule tentative**,
avec `.catchError((_) {})` silencieux.

**Impact :** si le serveur est injoignable au moment du raccrochage, le correspondant
continue de sonner jusqu'à son propre timeout (45 s web / 60 s mobile).

**Correction :** ajouter un retry dans `api_client.dart` pour le signal `bye`
(jusqu'à 3 tentatives avec backoff), ou dans `call_service.dart` autour des appels
`_api.signal(..., type: 'bye', ...)`.

---

## 🟠 ÉCARTS HAUTS (à corriger)

### 3. CallKit accept lit `type` au lieu de `media` → appel vidéo traité en audio

**Web** (`sw.js`) : distingue `data.media` (audio|video) avec repli sur `data.type`.

**Mobile** (`push_service.dart:151` et `:178`) : lit `data['type']` / `extra['type']`
au lieu de `data['media']` / `extra['media']`.

**Impact :** le backend envoie `media: video` et `type: incoming`. Le mobile lit
`type == 'incoming'` ≠ `'video'` → l'appel entrant accepté via CallKit est traité
en **audio** au lieu de **vidéo**. **Régression fonctionnelle probable.**

**Correction :**
```dart
// push_service.dart, lignes 147-152 et 174-179
// Remplacer 'type': data['type'] ?? 'audio' par :
'type': (data['media'] ?? data['type'] ?? 'audio') == 'video' ? 'video' : 'audio',
```

---

### 4. `from_user_id` absent sur mobile (multi-appareils)

**Web** : le web vient d'ajouter `from_user_id` dans `handleIncomingCall`, le message
SW et les query params URL. Il l'utilise pour router les bye vers tous les appareils
de l'utilisateur appelant quand le device exact est inconnu.

**Mobile** (`call_service.dart` + `push_service.dart`) : **aucune gestion** de
`from_user_id`.

**Impact :** en multi-appareils, un bye routé par user ne peut pas être géré côté
mobile. Le mobile ne peut pas non plus router ses propres bye par user.

**Correction :**
- `call_service.dart` `handleIncomingCall` : lire `data['from_user_id']` et le stocker
  (ex. `targetUserId`).
- `push_service.dart` : transmettre `from_user_id` dans `CallKitParams.extra` et dans
  les handlers accept.

---

### 5. bye routé par device OU par user (pas les deux)

**Web** (`sendSignal`) : pour le bye, envoie **à la fois** `to_device_id` (si connu)
**et** `to_user_id` (si connu) → couvre les deux routes.

**Mobile** (`call_service.dart`) : `refuse()` ne passe que `toDeviceId` ;
`hangUp()` passe `toDeviceId` si `rid != null`, sinon `toUserId`. **Jamais les deux.**

**Impact :** en multi-appareils, un bye qui part en `to_device_id` seulement ne
touche que le device spécifique, pas les autres appareils de l'utilisateur.

**Correction :** dans `refuse()` et `hangUp()`, passer `toDeviceId` **et** `toUserId`
quand les deux sont connus.

---

## 🟡 ÉCARTS MOYENS (à corriger)

### 6. Timeout d'appel sortant — 60 s (mobile) vs 45 s (web)

**Web** (`spa-calls.js`) : **45 s** — `setTimeout(..., 45000)`.

**Mobile** (`call_service.dart:105`) : **60 s** — `Timer(const Duration(seconds: 60))`.

**Impact :** durées différentes pour le même scénario d'abandon. Le mobile laisse
sonner 15 s de plus.

**Correction :** passer à `const Duration(seconds: 45)`.

---

### 7. Handler "bye" — filtrage par `call_id` (mobile) vs par `from_device_id` (web)

**Web** (`spa-calls.js:269-290`) : logique multi-appareils durcie — ignore les bye
d'un device tiers (`from && from !== currentCallPeerId`), accepte le bye de l'appelant.

**Mobile** (`call_service.dart:260-293`) : filtre par `call_id` quand `remoteId` est
null, et exige `from != null` (un bye legacy sans `from_device_id` est ignoré).

**Impact :** approche différente. Le mobile ignore un bye legacy (sans
`from_device_id`) au moment de l'appel sortant avant l'answer, alors que le web
l'accepte si `currentCallTargetUserId` est connu.

**Correction :** aligner la logique mobile sur le web — accepter un bye sans `from`
si `targetUserId` est connu, et ignorer les bye d'appareils tiers quand le peer est
connu.

---

## ✅ POINTS DÉJÀ ALIGNÉS (rien à faire)

| Comportement | Web | Mobile | Statut |
|---|---|---|---|
| Ringback (sonnerie sortante) | ✅ présent | ✅ présent | Aligné |
| bye avec `reason:reject`/`reason:cancel` | ✅ | ✅ | Aligné |
| Appels entrants ignorés quand occupé | ✅ | ✅ | Aligné |
| Config runtime dynamique (Pusher/TURN) | ✅ | ✅ | Aligné |
| Vibration `[400,200,400,200,400]` | ✅ | ✅ | Aligné |
| Push `incoming`/`reject`/`cancel` filtrés | ✅ | ✅ | Aligné |
| Champ `media` lu dans les push | ✅ | ✅ | Aligné (sauf CallKit, cf. #3) |

---

## 📋 PLAN D'ACTION RECOMMANDÉ

### Phase 1 — Critiques (à faire immédiatement)
- [ ] **#1** Délai de grâce 5 s + timer annulable (`call_service.dart`)
- [ ] **#2** Retry du bye (3 tentatives) (`api_client.dart` / `call_service.dart`)

### Phase 2 — Hauts
- [ ] **#3** CallKit lit `media` au lieu de `type` (`push_service.dart`)
- [ ] **#4** Gérer `from_user_id` (`call_service.dart` + `push_service.dart`)
- [ ] **#5** bye routé par device ET par user (`call_service.dart`)

### Phase 3 — Moyens
- [ ] **#6** Timeout sortant 45 s (`call_service.dart`)
- [ ] **#7** Handler bye aligné sur le web (`call_service.dart`)

---

## 🧪 TESTS DE VALIDATION APRÈS CORRECTION

1. **Appel sortant** : le ringback joue, timeout à 45 s si pas de réponse.
2. **Décrochage** : l'appel ne coupe pas (délai de grâce 5 s).
3. **Bascule Wi-Fi → 4G** pendant un appel vidéo : l'appel survit.
4. **Raccrochage avec serveur injoignable** : le bye est retenté, le correspondant
   arrête de sonner.
5. **Appel vidéo entrant accepté via CallKit** : s'ouvre bien en vidéo (pas en audio).
6. **Multi-appareils** : un bye d'un appareil tiers ne tue pas l'appel ; un bye de
   l'appelant arrête la sonnerie.
7. **Notification en arrière-plan** : sonne + CallKit affiché.

---

## 📌 RAPPEL — Contrat push FCM commun (web + mobile)

```json
{
  "type": "incoming | reject | cancel",
  "call_id": "uuid-de-l-appel",
  "from_device_id": "device-de-l-emetteur",
  "from_username": "nom-de-l-appelant",
  "from_user_id": "id-utilisateur-de-l-appelant",
  "media": "audio | video"
}
```

> `type` = type de notification, `media` = type de média. Ne pas confondre.
> `from_user_id` a été **ajouté récemment** au backend (CallController + PushService).
