# Changements apportés — Reprise du développement mobile Yam

Ce document regroupe **tous les changements effectués** par rapport au dernier
commit des deux dépôts, pour faciliter la reprise par le nouveau développeur.

> **Derniers commits de référence :**
> - `yam-api` : `133b80f` — "fix: normaliser les numéros de téléphone (E.164 +228) et corriger le raccrochage"
> - `yam-mobile` : `40509ae` — "fix: corriger le raccrochage (bye) et ajouter le choix appel vocal/vidéo"

---

## 1. BUG CRITIQUE CORRIGÉ — Notifications push FCM jamais envoyées

### Problème
Le backend **n'envoyait jamais** les notifications push FCM aux appareils mobiles.
Quand on appelait un appareil hors application, rien ne le réveillait.

### Cause racine
Le champ `fcm_token` était dans `$hidden` du modèle Eloquent `Device`
(`api/app/Models/Device.php`), pour ne pas fuiter via l'API. Mais
`CallController::sendPushNotification()` utilisait `$device->toArray()`, qui
**exclut** les champs cachés. Donc `PushService::notifyDevice()` voyait toujours
`fcm_token` vide et tombait dans le fallback Web Push (qui échouait).

### Correction
Dans `api/app/Http/Controllers/CallController.php`, méthode
`sendPushNotification()` :

```php
// AVANT (bug) :
app(PushService::class)->notifyDevice($device->toArray(), $payload);

// APRÈS (corrigé) :
$data = $device->makeVisible(['fcm_token', 'web_push_subscription'])->toArray();
app(PushService::class)->notifyDevice($data, $payload);
```

### Vérification
- Log backend : `[push] FCM v1 envoyé à device-mr3bpowh`
- Log mobile (logcat) : `[YAM][PUSH][BG] Appel entrant en arrière-plan` + `Écran CallKit affiché`

---

## 2. Champ `type` dans les notifications push (incoming / reject / cancel)

### Objectif
Permettre au mobile de distinguer le type de notification reçue et d'agir de
manière optimale :
- `incoming` : appel entrant → afficher l'écran d'appel natif (CallKit)
- `reject` : l'appel a été refusé par le destinataire → ne PAS afficher CallKit
- `cancel` : l'appel a été annulé par l'appelant → ne PAS afficher CallKit

### Contrat des données push (FCM `data`)
Chaque notification push contient désormais :
```json
{
  "type": "incoming | reject | cancel",
  "call_id": "uuid-de-l-appel",
  "from_device_id": "device-de-l-emetteur",
  "from_username": "nom-de-l-appelant",
  "media": "audio | video"
}
```

> **Note importante** : le champ média a été **renommé** de `type` vers `media`
> pour éviter la collision avec le nouveau champ `type` (incoming/reject/cancel).
> Le champ `type` désigne maintenant le **type de notification**, et `media`
> désigne le **type de média** (audio/vidéo).

### Backend (API Laravel)

#### `api/app/Http/Controllers/CallController.php`
- Dans `ring()` : ajout de `'type' => 'incoming'` et renommage du champ média
  `'type' => $type` → `'media' => $type` dans le payload de la push.

#### `api/app/Http/Controllers/SignalController.php`
- Nouvelle méthode `notifyCallEnd()` : quand un signal `bye` est reçu, le serveur
  détermine le sens du bye grâce à l'offre différée (`call_offers`) et envoie la
  push correspondante à l'autre partie :
  - le `bye` vient de l'**appelant** → push `cancel` au destinataire
  - le `bye` vient du **destinataire** → push `reject` à l'appelant
- `notifyCallEnd()` est appelé **AVANT** `handleDeferredOffer()` (qui supprime
  l'offre de `call_offers`, nécessaire pour déterminer le sens).
- Ajout d'un `Log::info('CallSignal reçu', [...])` pour le diagnostic.

#### `api/app/Services/PushService.php`
- `sendFcm()` : le payload FCM contient désormais `type` (incoming/reject/cancel)
  et `media` (audio/video) au lieu de `type` (audio/video).
- `sendWebPush()` : idem pour le fallback Web Push.

### Mobile (Flutter)

#### `lib/services/push_service.dart`
- `firebaseMessagingBackgroundHandler` (app en arrière-plan / fermée) :
  - ignore les push non-`incoming` (ne loggue pas "Appel entrant", n'affiche pas
    l'écran CallKit pour `reject`/`cancel`)
  - lit le type de média depuis `media` (au lieu de `type`)
- `onMessage` (app au premier plan) : ne déclenche un appel entrant que pour
  `incoming`
- `onMessageOpenedApp` (notification tapée) : idem
- `getInitialMessage` (cold start) : idem

#### `lib/services/call_service.dart`
- `refuse()` : envoie `payload: {'reason': 'reject'}` dans le `bye` (le
  destinataire refuse l'appel).
- `hangUp()` : envoie `payload: {'reason': 'cancel'}` quand on annule un appel
  sortant avant réponse (phase `calling`). Sinon payload vide (fin d'appel
  normale).

### Web (JS) — `web/js/spa-calls.js` (synchronisé vers `api/public/js/`)
- `refuseIncomingCall()` : envoie `sendSignal("bye", { reason: "reject" })`.
- `hangUp()` : envoie `sendSignal("bye", callStartTime ? {} : { reason: "cancel" })`
  (cancel quand l'appelant annule avant réponse).
- Log de debug `[YAM] bye reçu → ...` dans le handler `bye`.

---

## 3. Raccourcissement du délai de grâce de coupure (raccrochage)

### Problème
Quand l'autre partie raccrochait, l'appel ne coupait pas immédiatement (jusqu'à
5 s de délai) si le signal `bye` n'arrivait pas (WebSocket coupé).

### Correction
Réduction du délai de grâce `onConnectionState` (mécanisme de secours qui coupe
l'appel si la connexion WebRTC reste `disconnected`) :
- **Mobile** (`lib/services/call_service.dart`) : de `5 s` → `1500 ms`
- **Web** (`web/js/spa-calls.js`) : de `5000 ms` → `1500 ms`

---

## 4. Rappel — Changements du commit précédent (déjà poussés)

Pour mémoire, le commit `133b80f` (yam-api) et `40509ae` (yam-mobile)
contenaient déjà :
- Normalisation des numéros de téléphone (E.164, indicatif `+228` Togo) à
  l'inscription et à la connexion.
- Migration de fusion des doublons de numéros (transfert devices, tokens,
  call_offers, sessions ; gestion des doublons de device_id).
- Correction du raccrochage côté mobile et web.
- UI mobile : deux boutons "Appeler" (vocal) et "Vidéo" sur l'écran d'accueil.

---

## 5. Fichiers modifiés (non commités, à committer)

### Dépôt `yam-api`
- `app/Http/Controllers/CallController.php` — push incoming + fix fcm_token caché
- `app/Http/Controllers/SignalController.php` — push reject/cancel (notifyCallEnd)
- `app/Services/PushService.php` — champ type/media dans les push
- `public/js/spa-calls.js` — reason reject/cancel + délai 1,5 s
- (source : `web/js/spa-calls.js`)

### Dépôt `yam-mobile`
- `lib/services/push_service.dart` — gestion du type incoming/reject/cancel
- `lib/services/call_service.dart` — reason reject/cancel + délai 1,5 s

---

## 6. Commandes utiles pour la reprise

```bash
# Synchroniser le JS web vers api/public (après modif de web/js/*.js)
./scripts/sync-web.sh

# Redémarrer l'API Laravel
php artisan serve --host=0.0.0.0 --port=8000

# Redémarrer Reverb (WebSocket)
php artisan reverb:start --host=0.0.0.0 --port=6001

# Rebuild + install APK mobile
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

**Important** : après une modification PHP, **redémarrer** `php artisan serve`
(il ne recharge pas le code automatiquement).
