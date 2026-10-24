# PicasaNext — référence technico-fonctionnelle

PicasaNext est un remplaçant natif macOS de Picasa 3.9 (Google, abandonné en 2016) pour une photothèque
de plusieurs centaines de milliers de fichiers (référence : 207 146 fichiers, 780 Go sur un NAS).
Il reprend les données de Picasa (`.picasa.ini`, `contacts.xml`, base `db3`) et apporte l'analyse
d'image moderne d'Apple (Vision) : visages, animaux, scènes, doublons, rafales.

Principe directeur : **les dossiers de photos ne sont jamais modifiés**. Tout ce que l'application
sait ou décide vit dans une bibliothèque séparée ; l'écriture sur disque (`.picasa.ini`, XMP) est un
export explicite.

---

## 1. Architecture

| Module | Rôle | Taille |
|---|---|---|
| `PicasaFormats` | Lecture / écriture des formats Picasa : `.picasa.ini`, `rect64`, filtres, `contacts.xml`, PMP, `thumbindex.db`, caches de vignettes | ~580 lignes |
| `PicasaCore` | La bibliothèque : SQLite, scan, métadonnées, vignettes, analyse Vision, identités (visages / animaux), regroupements, export | ~3 600 lignes |
| `PicasaViewer` | L'application SwiftUI + AppKit | ~4 000 lignes |
| `picasa-cli` | Toutes les opérations longues en ligne de commande | ~250 lignes |
| `Tests/Runner` | 126 vérifications de bout en bout sur des fichiers synthétiques | ~630 lignes |
| `Tools/` | Banc de mesure de l'indexation, calibration de la similarité | ~190 lignes |

Swift 6, macOS 14+, aucune dépendance externe (SQLite C, ImageIO, Vision, AVFoundation, MapKit).
Construction : `./build.sh` (swiftc direct) ou `swift build`.

**La bibliothèque** (`~/Library/Application Support/PicasaNext Library`, déplaçable via `--library`
ou `PICASANEXT_LIBRARY`) :
- `library.sqlite` — l'index (WAL, un acteur Swift sérialise les accès) ;
- `thumbs/ab/cd/<id>.jpg` — une vignette JPEG 320 px par fichier (~23 Ko) ;
- `thumbs/faces/` — recadrages des visages / animaux affichés dans People / Animals.

Supprimer la bibliothèque ne touche à aucune photo ; elle se reconstruit (`picasa-cli all`).

Le schéma est versionné (`PRAGMA user_version`, v11) et migré à l'ouverture.

---

## 2. Pipeline de traitement

```
scan ──► index (métadonnées + vignettes) ──► analyze (Vision) ──► suggestions ──► regroupements
```

Chaque photo porte un **état par étape** (`meta_state`, `thumb_state`, `face_state`,
`analysis_state` : 0 à faire, 1 fait, 2 indécodable, 3 illisible — réessayé au passage suivant).
Toutes les étapes sont **incrémentales** et **reprennent où elles en étaient** ; l'application et
la CLI peuvent tourner en même temps sur la même bibliothèque.

### 2.1 Scan (`picasa-cli scan ROOT`, `rescan`)
- Parcours parallèle des dossiers ; seules les métadonnées du système de fichiers sont lues
  (taille, date) : un rescan de 2 To ne relit aucun fichier.
- Un fichier modifié (taille / date) repart pour toutes les étapes ; les décisions humaines sont
  conservées (voir 5.4).
- Exclusions : dossiers `thumbs`, `thumbnails`, `previews`, `cache(s)` toujours ignorés ; exclusions
  utilisateur mémorisées (`--exclude NOM|/chemin`).
- Sécurité : une racine vide alors que la bibliothèque en connaît le contenu (disque non monté) est
  refusée ; un dossier illisible n'est jamais purgé.
- Lecture des `.picasa.ini` au passage (seulement s'ils ont changé).

### 2.2 Index (`picasa-cli index`)
- **Métadonnées** (ImageIO / AVFoundation) : dimensions, orientation, date de prise de vue, GPS,
  appareil, durée vidéo, empreinte rapide de contenu (`quick_hash`), présence d'EXIF.
- **Vignettes** 320 px, orientation appliquée ; l'aperçu intégré au JPEG n'est utilisé que s'il est
  assez grand.
- Les deux étapes avancent **par lots alternés** (métadonnées puis vignettes) : les photos
  apparaissent dans l'app au fil de l'eau.
- **Réglages par défaut mesurés sur NAS** (`Tools/bench-index.swift --real`) : 4 lectures en
  parallèle, lots de 8 (~5,6 photos/s, CPU ~15 %, ~17 Mo/s ; au-delà de 4 lectures le partage
  réseau sature). `-j N` et `--batch N` pour changer.
- **Disque qui disparaît** : si le dossier d'un fichier en échec n'existe plus, l'étape s'arrête
  sans rien marquer (au lieu de déclarer illisible tout ce qui reste).
- **Petites images ignorées** : côté < 200 px, ou < 512 px sans EXIF d'appareil (vignettes écrites
  par d'autres logiciels). Réglable (`--min-size`, `--thumb-size`), réévalué sans rescan.
- **Dates estimées** quand la photo n'a pas de date : nom de fichier (`IMG_20160910_162536`,
  `WhatsApp Image 2020-03-01 at …`), puis dossiers du plus proche au plus lointain (jour, mois,
  année), puis date du fichier. L'origine est mémorisée (`date_source`) et affichée.

### 2.3 Analyse Vision (`picasa-cli analyze`)
Un seul décodage par photo (1 600 px), plusieurs requêtes Vision :
- détection des **visages** + empreinte (feature print) de chaque visage ;
- **classification de scène** (labels à 90 % de précision) ;
- **animaux** (chats, chiens) + empreinte de chaque animal ;
- **empreinte de l'image entière** (similarité) ;
- **score esthétique** et drapeau « document / capture » (macOS 15+).

Lots de 8 photos, enregistrés photo par photo. Une photo ouverte dans la visionneuse et pas encore
analysée l'est immédiatement.

---

## 3. Vues

### 3.1 Grilles
- Grille virtualisée (NSCollectionView) : fluide à 200 000 éléments ; seules les cellules visibles
  existent.
- **Sections par année** avec en-têtes collants et rail des années à droite.
- Ne montre que les photos **indexées** (métadonnées + vignette) et **non masquées** (copies,
  petites images, cachées dans Picasa).
- **Rafraîchissement en direct** : l'app interroge un compteur de changements de la base toutes les
  2 s (1 s sur « Last indexed ») ; rechargement complet au plus toutes les 10 s pendant un scan.
  Position et sélection conservées ; dans une liste qui grossit par le haut, la grille ne bouge pas
  tant qu'on n'est pas en haut (bouton « ↑ N new »).
- Bouton **Top** dès qu'on a défilé.
- Groupes à deux niveaux (Duplicates, Bursts, Similar) : une couverture par groupe avec badge
  « ×N » ; clic sur le badge ou double-clic : la série se déplie en place.

### 3.2 Barre latérale
- **Library** : All photos, Last indexed (2 000 derniers indexés), Starred, Videos, People,
  Relations, Animals, Labels, Places.
- **Discover** : Best photos (10 % les mieux notés hors documents), Duplicates, Similar, Bursts,
  Estimated dates, Screenshots & documents, Small images (ignored).
- Albums (Picasa), Years, Folders (clic droit : Show in Finder).

### 3.3 Barre d'outils
Titre, puis quatre zones : dernier scan · photos / vidéos affichées · traitement en cours (« N to
index, M to analyze », roue si l'app ou la CLI travaille, clic = détail par étape, fichiers
illisibles, disques montés) · Show in Finder (⇧⌘R) et Add Folder.

### 3.4 Visionneuse
- Plein cadre dans la fenêtre ; **F** plein écran ; **Espace / Échap** ferme ; **Entrée**
  lecture / pause des vidéos ; ← → photo précédente / suivante ; **S** étoile.
- Zoom au pincement ou double-clic (l'original pleine résolution est chargé au zoom), déplacement.
- **Cadres** des visages (vert = nommé, jaune = suggestion, pointillé blanc = inconnu) et animaux
  (orange) avec étiquettes ; un clic ouvre une bulle : nommer (noms existants proposés, Tab
  complète), confirmer / rejeter une suggestion, « Not X » sur un nom confirmé, ignorer.
- Panneau d'informations : fichier, date (avec « estimée depuis … »), appareil, lieu, légende,
  tags, personnes ; **Shooting** (objectif, exposition, ISO, focale, flash, balance des blancs,
  mesure, altitude, logiciel, profil couleur) ; détections (animaux, labels, esthétique, similaires,
  rafale) ; **copies identiques** et leurs chemins.

### 3.5 Places
- Carte MapKit, styles **Map / Satellite / Hybrid**, **3D** (relief) ; zoom identique dans tous les
  styles (bornes de caméra) et boutons + / −.
- Pastilles regroupées selon le zoom (grille de ~10 cellules, calcul linéaire hors du fil
  principal), photo la mieux notée en couverture ; panneau des photos de la pastille ou de la zone.

### 3.6 Labels
Une carte par label Vision ou mot-clé Picasa, meilleure photo en couverture, nombre de photos.

### 3.7 Recherche
Jetons (personnes, labels, albums) combinés en ET + texte libre (nom, dossier, légende, appareil,
tags, labels, espèces, personnes, animaux, albums) ; autocomplétion, Tab accepte.

---

## 4. People et Animals (identités)

Les visages (→ personnes) et les animaux (→ animaux nommés) suivent le même modèle (`IdentityKind`).

### 4.1 Écran
- Barre de filtres : **Groups / Photos**, année, **Named / To identify / Ignored** (les inconnus
  sont masqués par défaut, un bouton les propose).
- **Groups** : cartes rondes (visage le plus grand en couverture). Glisser une personne sur une autre
  = fusion ; un groupe sur une personne = nommer. **Sélection multiple** : ⇧-clic (plage), ⌘-clic,
  rectangle tracé dans le vide ; au relâchement, bulle à la souris : *Name as… / Merge into…*,
  *Ignore*, *Restore*.
- **Photos** : grille par année ; **Frames** (cadres sur les vignettes : cible en couleur, plein si
  confirmé, pointillé sinon) et **Frame only** (chaque vignette zoomée sur sa cible).
- Fiche d'une personne : **Confirmed / Suggested** ; sur les suggestions *Confirm*, *Reject*,
  *Confirm all*, *Reject all* ; sur les confirmées *Not X* et *Move to…* ; renommer (un nom existant
  fusionne). La grille remonte en haut après chaque action.
- **Homonymes** : bandeau « N noms portés par plusieurs personnes » et aperçu avant fusion
  (comparaison sans casse, accents ni espaces ; fusion vers la fiche la plus fournie). CLI :
  `merge-duplicates [--apply]`.

### 4.2 Regroupement des inconnus
Regroupement « leader » sur les empreintes : un visage rejoint le premier groupe dont le leader est à
une similarité cosinus ≥ 0,80 ; les 5 000 plus grands visages, pour rester interactif. Les éléments
sans empreinte exploitable sont proposés un par un.

### 4.3 Suggestions de noms
- Chaque personne est résumée par son **visage moyen** (centroïde normalisé de ses visages
  confirmés).
- Chaque visage sans nom reçoit la personne la plus proche si la similarité est **≥ 0,82**.
- **Contre-exemples** : les visages rejetés (ou retirés) pour une personne sont des « pas lui ».
  Un visage plus proche d'un contre-exemple de X que du visage moyen de X n'est pas suggéré comme X
  (la personne suivante est essayée) : corriger quelques erreurs efface aussi leurs sosies.
- Recalcul complet après chaque modification (~1–2 s pour 100 000 visages, produit matriciel
  vDSP) ; `picasa-cli suggest` à la demande.

### 4.4 Animaux
Même fonctionnement ; l'empreinte est celle de l'animal recadré. Les animaux d'aspect proche (deux
chats tigrés) se distinguent mal : les corrections servent de garde-fou.

### 4.5 Décisions humaines
Nommer, ignorer, restaurer, confirmer, rejeter, retirer, déplacer marquent l'élément `human = 1`
(+ date). Les relances (`analyze --redo`, rescan d'un fichier modifié, ré-import Picasa) ne défont
jamais ces décisions ; `analyze --redo --include-manual` les remet à zéro.

---

## 5. Doublons, rafales, similaires

Calcul `picasa-cli similar` (~20–25 s pour 207 000 fichiers, empreintes chargées par fenêtre de temps)
et à la fin de chaque `analyze`. Ordre et exclusivité : doublons, puis rafales parmi les copies
gardées, puis similaires parmi le reste. Chaque groupe a sa couverture précalculée (`group_info`) :
les vues s'ouvrent en ~0,1–0,4 s.

« Ressemblance » = similarité cosinus des empreintes d'image entière (0–1). Sur la bibliothèque de
référence : deux photos au hasard 0,50 en médiane, 0,70 au 99ᵉ centile ; les couvertures de deux
groupes voisins (≤ 60 s, même appareil) 0,79 en médiane.

### 5.1 Duplicates — la même image
- Fichiers identiques : même `quick_hash` + même taille.
- Même photo dans un autre fichier (redimensionnée, recompressée) : même seconde de prise de vue et
  ressemblance ≥ 0,985.
- Copie gardée : la plus grande en pixels, puis hors dossiers « de copie » (`__duplicate`,
  `doublon`, `_a_trier`, `recuva`, `#recycle`, `backup`, `sauvegarde`, `copie`, `copy`, `old`,
  `tmp`, `export`…), puis la moins profonde, puis la première indexée.
- Les autres (`dup_of`) sont masquées partout sauf dans leur dossier et dans Duplicates.

### 5.2 Bursts — une série prise d'affilée
- Rafale : même appareil, ≤ 3 s entre deux photos, ressemblance ≥ 0,85 (≥ 0,92 sans EXIF
  d'appareil), date issue de la photo, ≥ 2 photos.
- Timelapse : ≥ 5 photos à intervalle régulier (±15 %, jusqu'à 60 s), ressemblance ≥ 0,80.
- Fichiers d'appareil sans date (GoPro) : ordre des numéros de fichier dans le dossier, ≥ 5,
  ressemblance ≥ 0,80.
- Couverture : la mieux notée (la première en cas d'égalité).

### 5.3 Similar — la même scène
Deux photos sont liées si elles se ressemblent et que les métadonnées concordent :

| EXIF | Ressemblance |
|---|---|
| Même appareil, ≤ 2 min | ≥ 0,75 |
| Même appareil, ≤ 10 min | ≥ 0,88 |
| ≤ 100 m (GPS), ≤ 30 min | ≥ 0,90 |
| ≤ 10 min sans autre indice | ≥ seuil (0,97, `--threshold`) |
| Dates estimées | même dossier, ≥ seuil |

Garde-fou anti-chaîne : ressemblance ≥ 0,72 avec la première photo du groupe. Couverture : la mieux
notée.

---

## 6. Relations
- Graphe des personnes photographiées ensemble : un lien par paire (épaisseur = nombre de photos
  communes), seuil « au moins N photos ensemble » ; option **Moments** (carrés = photos d'un même
  groupe de personnes).
- Cercles de famille / amis par **Louvain** sur les co-occurrences normalisées ; halos colorés.
- Placement par forces (calcul hors fil principal, positions conservées entre réglages).
- Clic : liens et photos partagées ; double-clic : vue centrée (anneaux par proximité) ;
  ⌘-clic ×2 : plus court chemin entre deux personnes ; curseur d'années (année seule ou cumul) avec
  lecture.

---

## 7. Données Picasa

### Import (lecture seule)
- `.picasa.ini` (pendant le scan) : étoiles, légendes, visages et noms (`[Contacts2]`, `rect64`
  ÷ 65 535), albums locaux (`[.album:token]`), mots-clés, rotation, chaîne de retouches. Encodage
  UTF-8 ou CP1252, noms NFC / NFD.
- `contacts.xml` : noms des contacts.
- `db3` (optionnel) : tables PMP, `thumbindex.db`, caches de vignettes ; appariement des chemins par
  composants de fin + taille (bibliothèque déplacée ou venue de Windows).

### Export (opt-in) — `picasa-cli export [--format picasa|xmp|all] [--dry-run] [PATH]`
- `.picasa.ini` : étoiles, légendes, visages nommés + `[Contacts2]`, mots-clés, albums ; ancien
  fichier en `.picasa.ini.bak` ; clés inconnues conservées ; relecture sans doublon de visages.
- XMP (`IMG_0001.xmp`) : note, légende, mots-clés, personnes et animaux en régions MWG, mots-clés
  hiérarchiques `People|`, `Pets|`, `Albums|` ; un XMP créé par un autre logiciel n'est jamais
  écrasé.

---

## 8. Ligne de commande

| Commande | Rôle |
|---|---|
| `scan ROOT… [--exclude …]`, `rescan`, `roots`, `remove-root`, `excludes`, `unexclude` | sources |
| `index [--batch N] [--redo-thumbs] [--min-size] [--thumb-size]` | métadonnées + vignettes |
| `analyze [--redo [--include-manual]] [--batch N]` | Vision, suggestions, regroupements |
| `similar [--threshold T]` | doublons, rafales, similaires |
| `suggest` | recalcul des suggestions |
| `merge-duplicates [--apply]` | homonymes |
| `import-contacts`, `import-db3` | données Picasa |
| `export [--format …] [--dry-run]` | écriture sur disque |
| `stats`, `all` | résumé ; scan + index + analyze |

Options globales : `--library DIR`, `-j N`.

---

## 9. Performance (bibliothèque de référence, MacBook M2 Pro, NAS SMB)

| Opération | Mesure |
|---|---|
| Démarrage (compteurs + grille) | < 1 s (index couvrants ; avant : ~5 s) |
| Grille All | 131 ms de requête (avant index : 745 ms), mesuré le 23 oct. avant le masquage des copies |
| Ouverture Bursts / Similar / Duplicates | 0,16 / 0,11 / 0,4 s (avant : 20 s pour Bursts) |
| Regroupements complets | ~20–25 s (64 120 groupes de doublons, 91 244 copies masquées) |
| Suggestions (100 000 visages) | ~1,8 s |
| Indexation sur NAS | ~5,6 photos/s (réseau saturé à 4 lectures), soit ~10 h pour 200 000 fichiers |

---

## 10. Limites connues
- Le schéma de base n'est pas rétro-compatible (pas de retour à une version antérieure).
- Les animaux d'aspect très proche se distinguent mal.
- `db3` : testé sur des fichiers synthétiques seulement.
- Pas de retouche d'image ; pas de partage en ligne.
- Signature ad hoc par défaut : macOS redemande l'accès au volume réseau après chaque build
  (`SIGN_IDENTITY` pour une signature stable).
