# Jarvis

Jarvis est le compagnon de developpement local de l'ecosysteme Adansonia.
Il percoit le contexte de travail autorise, Limule raisonne et Limule Bridge
execute les actions explicitement autorisees.

## Architecture

```text
LIMULE  : intelligence, raisonnement et memoire durable
JARVIS  : contexte local, interaction, orchestration et presence
BRIDGE  : actions systeme et connecteurs autorises
```

## Organisation

```text
apps/jarvis-macos  Application native SwiftUI pour la premiere version macOS
services/core      Sessions, contexte, orchestration et etat des projets
services/observer  Evenements fichiers, Git, logs et processus autorises
services/voice     Capture audio, STT, TTS et interruption vocale
services/bridge    Client Limule Bridge, permissions et actions
packages/          Protocoles, schemas d'evenements et clients partages
database/          Migrations et schemas SQLite locaux (historique de chat)
docs/              Architecture, API, securite et protocoles
tests/             Tests unitaires, integration et fixtures
```

`services/*` et `packages/*` restent des emplacements reserves pour une
architecture multi-processus future. La V1 vit entierement dans
`apps/jarvis-macos` : la logique d'orchestration, d'observation et d'actions
Bridge y est implementee directement (`ProjectStore`, `ProjectWatcher`,
`JarvisBridge`) plutot que dans des services separes.

## Premiere promesse produit

> "Jarvis, ou en suis-je sur ce projet, et aide-moi a reprendre le travail."

La V1 est volontairement centree sur les projets Adansonia autorises, dans cet
ordre : Limule, ZOLA, puis KOMPTA.

### Ce qui est fonctionnel aujourd'hui

- **Contexte Git** — branche, dernier commit, fichiers modifies, activite des
  7 derniers jours.
- **Fichiers recents** — les fichiers les plus recemment modifies du projet
  focus (hors `.git`, `node_modules`, `build`, etc.).
- **Observation live** — le projet focus est surveille via FSEvents ; le
  dashboard se met a jour tout seul quand un fichier change, sans clic sur
  Actualiser.
- **Etat de build** — detection de l'outil (Xcode, npm, cargo, swift build,
  make), execution a la demande, notifications macOS sur les transitions
  succes/echec.
- **Conversations Limule contextualisees** — plusieurs fils de discussion
  distincts (persistes en SQLite local, survivent a un redemarrage complet de
  l'app), avec bouton "nouvelle conversation" et historique pour revenir a un
  fil precedent. Chaque appel a l'API Limule envoie une fenetre de contexte
  bornee (les derniers echanges du fil actif) plutot qu'un message isole sans
  memoire. Rendu markdown reel (gras, italique, titres, blocs de code
  copiables) au lieu des asterisques bruts. Le rendu reconnait aussi les
  listes, citations et separateurs, avec une hierarchie visuelle claire pour
  les analyses plus longues.
- **Memoire de travail par projet** — `ProjectMemoryStore` ecrit un contexte
  local et explicite dans `Application Support/Jarvis/project-memory.json` :
  derniere demande, derniere reponse et decisions recentes pour chaque
  projet. Cette memoire est visible et effacable depuis Connexions, puis
  envoyee au cerveau Limule lors des conversations suivantes.
- **Preferences durables** — section "Preferences" en tete de Connexions :
  notes libres (`UserPreferencesStore`, persistees localement) sur la
  maniere de travailler avec Jarvis, injectees dans chaque appel au cerveau
  Limule tant qu'elles restent ecrites — pas d'extraction automatique, Davy
  les ecrit lui-meme. Le system prompt calibre aussi la longueur de reponse
  a la question (courte pour une confirmation, developpee pour une analyse)
  et privilegie une recommandation directe a une question ouverte quand une
  option est clairement meilleure.
- **Apprentissage a partir des vrais echec** — les echec des actions
  systeme, fichiers et LIMULE Bridge sont deja audites ; Jarvis en construit
  maintenant un digest automatiquement ajoute au contexte du cerveau. Il
  peut donc eviter de proposer a nouveau une action qui vient reellement
  d'echouer, sans inventer de faux souvenir.
- **Contexte projet robuste** — une demande qui vise clairement un projet
  connu (par exemple "pour ZOLA" ou "dans Limule") bascule le focus avant
  d'etre envoyee au cerveau. Les simples comparaisons ne changent pas le
  focus par accident. Une protection anti-boucle detecte une reponse longue
  trop proche d'une reponse recente et demande une reformulation au cerveau.
- **Git et GitHub depuis le cerveau** — les outils exposes a Limule couvrent
  la liste des depots GitHub accessibles avec le token connecte, l'etat Git
  local, le commit et le push du projet actif. Une demande explicite de PR
  peut appeler `gh pr create` sur la branche active ; GitHub CLI doit etre
  installe et authentifie sur le Mac pour cette derniere operation.
- **Actions Bridge controlees** — ouverture Finder/editeur, creation de
  branche git, centralisees dans `JarvisBridge` plutot qu'eparpillees dans
  l'UI.
- **Presence** — l'icone Jarvis reste toujours visible dans la barre de
  menus, avec un badge de statut (echec de build, ecoute active) au lieu
  d'etre remplacee. Ecoute optionnelle de double-clap (heuristique RMS
  locale, plusieurs paliers de rythme acceptes, rien n'est enregistre) pour
  ramener Jarvis au premier plan meme reduit ou ferme et declencher une
  salutation parlee (`ProjectStore.greetFromClap`) ; la salutation enchaine
  directement sur le mode conversation mains-libres (ci-dessous), sans clic
  supplementaire.
- **Animation de reflexion** — un orbe de particules (rendu Canvas/SwiftUI)
  avec un etat "solving" (ondulation active) pendant que Jarvis compose sa
  reponse. Un second orbe en verre liquide (rendu Metal, `LiquidOrbView`)
  reagit en temps reel au niveau/timbre/rythme de la voix pendant la lecture
  d'une reponse parlee.
- **Trousseau resilient** — le stockage des cles API (Limule, GitHub) se
  repare automatiquement si son autorisation macOS devient obsolete apres un
  rebuild, au lieu de redemander confirmation en boucle.
- **Synchronisation cloud (Limule)** — l'historique de conversation et la
  liste de projets se retrouvent identiques sur plusieurs machines via
  l'API `/api/v1/state/*` de Limule (meme cle `lim_...` que le chat, scope
  `state`). Dernier-ecrit-gagne pour les projets et les metadonnees de
  conversation, mais les messages fusionnent par id (jamais supprimes) pour
  qu'une synchro tardive ne perde jamais d'historique. Reglages et
  permissions Bridge restent locaux a chaque machine. Voir
  `WorkspaceSyncService`, section "Synchronisation" de Connexions.

### Actions systeme (Bridge)

Chantier separe des quatre actions Bridge historiques (Finder, editeur,
branche git, note) : celles-ci restent des operations de fichiers/process
directes, sans risque particulier. Les actions systeme ci-dessous, elles,
pilotent reellement le Mac (clic, frappe clavier, mise au premier plan) via
l'API Accessibilite macOS (`AXUIElement` pour trouver/cliquer un controle et
mettre une fenetre au premier plan, `CGEvent` pour simuler une frappe
clavier) — d'ou un encadrement beaucoup plus strict.

- **Scope ferme des le depart** — pas de "cliquer n'importe ou" ni de
  "taper n'importe quoi n'importe ou". Le catalogue (`SystemActionCapability`)
  fixe des cibles nommees et concretes : le bouton *Build* de Xcode, la
  fenetre de VS Code/Xcode, le champ actuellement focus de l'un des deux.
  Ajouter une capacite veut dire ajouter un cas au catalogue, pas exposer une
  primitive generique (coordonnees, bundle ID arbitraire) a l'appelant.
- **Permission Accessibilite macOS** — verifiee via `AXIsProcessTrusted` au
  premier usage ; si elle manque, Jarvis declenche le prompt systeme puis
  peut rouvrir directement Reglages Systeme > Confidentialite et securite >
  Accessibilite (`AccessibilityPermission`).
- **Permission par action** — chaque capacite est desactivee par defaut et
  s'active individuellement dans Connexions > "Actions systeme (Bridge)"
  (`SystemActionPermissionStore`, persiste dans `UserDefaults`).
- **Confirmation explicite avant la premiere execution** — une capacite
  activee mais jamais encore utilisee declenche une alerte macOS
  ("Autoriser <action> ?", avec la cible exacte) avant d'agir ; plus jamais
  silencieuse comme les quatre actions historiques. Desactiver une action
  efface sa confirmation : la reactiver la redemande.
- **Journal d'audit persistant** — chaque execution (reussie, en echec ou
  refusee a la confirmation) est enregistree dans la meme base SQLite locale
  que l'historique de chat (`system_action_audit_log` dans
  `LocalDatabase`/`jarvis.sqlite3`) : horodatage, capacite, cible, resultat.
  Consultable dans Connexions > "Suivi" (fusionne avec le journal LIMULE
  Bridge ci-dessous).

Capacites disponibles aujourd'hui :

| Capacite | Ce qu'elle fait | Declencheur dans Jarvis |
| --- | --- | --- |
| Cliquer sur Build dans Xcode | Cherche le bouton "Build" dans la fenetre Xcode au premier plan et clique dessus | "clique sur build" |
| Mettre l'editeur au premier plan | Active VS Code ou Xcode (selon lequel tourne) | "focus editeur" / "editeur au premier plan" |
| Ecrire dans le champ actif de l'editeur | Simule une frappe clavier dans le champ focus de VS Code/Xcode, deja au premier plan | "ecris dans l'editeur \<texte\>" |

### LIMULE Bridge

Chantier distinct des actions systeme AXUIElement ci-dessus : un client pour
**LIMULE Bridge**, le serveur HTTP local (`http://127.0.0.1:8765`) que l'app
LIMULE fait deja tourner sur ce Mac pour son propre pilotage de la machine
(clic, clavier, presse-papiers, fenetres, fichiers, navigateur, messages,
rappels...). Jarvis ne le construit pas, il s'y connecte.

- **Auth partagee, jamais generee** — le jeton local vient d'un item
  Trousseau partage entre Jarvis et LIMULE via un Keychain Access Group
  (`264EZSM3VZ.com.adansonia.limule.shared`, meme Team ID Apple Developer).
  `LimuleBridgeAuthentication` ne fait que le *lire* (`SecItemCopyMatching`) ;
  seule l'app LIMULE elle-meme le cree. Si LIMULE n'a jamais tourne sur cette
  machine, le jeton est introuvable et Bridge est simplement indisponible —
  jamais d'erreur bloquante. Necessite que Jarvis soit signe avec le vrai
  Team ID (`project.yml`, `Jarvis.entitlements`) plutot qu'en ad-hoc.
- **Couverture complete, pas un sous-ensemble** — `LimuleBridgeAction`
  couvre les ~31 routes documentees (clic, frappe, fichiers, navigateur,
  messages, rappels, minuteurs...), chacune avec un resume d'audit redige a
  la main (jamais le contenu integral d'un fichier ou d'un message).
- **Aucune confirmation par action — decision assumee.** Contrairement aux
  actions systeme AXUIElement, LIMULE Bridge lui-meme n'a aucun garde-fou
  integre : il execute tout ce qu'on lui demande des qu'il recoit le bon
  jeton. Ajouter une confirmation bloquante cote Jarvis a ete envisage puis
  explicitement ecarte pour l'instant : le **Suivi** (journal d'audit) en
  tient lieu — chaque appel, reussi ou non, y est enregistre avant que le
  resultat ne soit retourne. Un interrupteur maitre unique
  (`LimuleBridgeSettings`, desactive par defaut, section "LIMULE Bridge" de
  Connexions) reste le seul frein cote Jarvis.
- **Suivi unifie** — le journal LIMULE Bridge (`limule_bridge_audit_log`)
  et celui des actions systeme AXUIElement sont fusionnes en une seule
  liste chronologique (`AuditTrailEntry`) dans Connexions > "Suivi", avec
  un badge distinguant l'origine de chaque entree. Repliable : 10 entrees
  affichees par defaut, bouton "Voir plus" pour en reveler davantage plutot
  qu'un historique complet toujours deroule.

### Workspace (fichiers et dossiers connectes)

Glisser-deposer plusieurs fichiers et/ou dossiers sur la fenetre Jarvis les
connecte a la conversation de facon persistante -- independant du projet
focus, jusqu'a retrait explicite.

- **Chips retirables** — chaque element connecte apparait comme une chip
  au-dessus du champ de saisie (`WorkspaceItemChip`), avec un bouton pour le
  retirer. La liste est persistee localement (`WorkspaceItem`, meme
  mecanisme `UserDefaults` que la liste de projets).
- **Depot multiple et separation image/document** — un seul glisser-deposer
  peut contenir plusieurs fichiers et dossiers a la fois. Une image continue
  d'etre affichee directement dans le chat (fence ```screenshot```, comme
  avant) ; tout le reste (documents, dossiers) rejoint le workspace au lieu
  d'etre imprime comme un message ponctuel.
- **Apercu au lieu de contenu integral** — a chaque appel au cerveau Limule,
  un apercu court de chaque element connecte (debut du fichier, ou liste des
  entrees de premier niveau d'un dossier -- `WorkspacePreviewComposer`) est
  inclus dans le prompt systeme, jamais le contenu complet. Le modele lit le
  detail a la demande via ses outils existants `read_file`/`search_files` --
  approche hybride retenue plutot qu'un pre-chargement complet (ne passe pas
  a l'echelle) ou un acces uniquement a la demande (le modele ne "voit" rien
  sans savoir explicitement quoi chercher).
- **Recherche prioritaire au workspace** — `search_files` cherche d'abord
  dans les dossiers connectes (jusqu'a la limite complete de resultats sur
  cette seule passe), puis complete avec le reste du Mac seulement s'il
  reste de la place -- un resultat pertinent du workspace ne peut plus etre
  ecrase par la troncature d'une recherche globale.
- **Visible aussi hors du chat** — le workspace connecte apparait dans le
  resume "Ou en suis-je" (`ResumeComposer`), pas seulement dans les chips du
  composer.

### Pipeline vocal (ElevenLabs)

Commande vocale et reponse parlee, via l'API REST ElevenLabs
(`ElevenLabsService`, auth par header `xi-api-key`, distinct de l'auth
Bearer utilisee par Limule/GitHub).

- **Mode conversation mains-libres** — un clic sur le micro (ou une
  salutation de clap qui se termine) demarre une boucle
  (`JarvisCommandView.runConversationLoop`) : ecoute avec arret automatique
  sur silence, envoi du texte transcrit comme s'il avait ete tape, attente
  de la fin de la reponse parlee, puis reecoute — jusqu'a un clic explicite
  sur le micro pour arreter. Plus besoin de relancer l'enregistrement a
  chaque tour.
- **Detection de fin de phrase (VAD)** — `VoiceRecorder.recordUntilSilence`
  s'appuie sur un `VoiceActivityDetector` dedie (RMS/plancher de bruit
  adaptatif, meme principe que la detection de clap mais inverse : silence
  soutenu plutot que pic bref), avec des seuils distincts pour demarrer et
  pour continuer une phrase — une syllabe plus faible en fin de phrase ne
  coupe pas le tour. Le silence doit durer 3,2s pour cloturer un tour, afin
  de survivre aux pauses naturelles de reflexion dans une longue phrase.
- **Capture et transcription** — `VoiceRecorder` (`AVAudioEngine` dedie,
  distinct de celui de la detection de clap, mise en pause pendant
  l'enregistrement puis reprise si elle etait active) capture en CAF natif
  puis convertit en PCM mono 16 kHz avant l'envoi a
  `POST /v1/speech-to-text` (`file_format=pcm_s16le_16`, modele
  `scribe_v2`) — plus fiable que de laisser l'inference de format deviner
  le conteneur.
- **Reponse parlee seulement si la question etait vocale** — `ProjectStore`
  suit un etat de session vocale separe (`VoiceSessionState` : idle,
  recording, transcribing, speaking). Un message tape au clavier ne
  declenche jamais de lecture audio. Quand la question venait du micro, la
  reponse de Jarvis est envoyee a `POST /v1/text-to-speech/{voice_id}/stream`
  (modele bas-latence `eleven_flash_v2_5`) et lue via `VoicePlayback`
  (`AVAudioPlayer`, avec un minuteur de secours si CoreAudio ne declenche
  jamais la fin de lecture), avec l'orbe `LiquidOrbView` affiche pendant la
  lecture.
- **Cle et voix dans Connexions** — section "ElevenLabs (voix)" : cle API
  (Trousseau, meme service que Limule/GitHub/Google), selecteur de voix
  peuple via `GET /v1/voices`, deconnexion.

### Pas encore fait

- `services/*` et `packages/*` comme processus/paquets reellement separes.
