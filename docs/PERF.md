# PicasaNext — analyse des lenteurs et correctifs (6 nov. 2026)

Mesures faites avec `sqlite3` sur une copie de `library.sqlite` placée dans `$TMPDIR/pn/lib.sqlite`. Contenu : 207 146 médias, 114 675 visages, 1,38 M labels, 0 tag (mots-clés).
**Avertissement :** dans le bac à sable, les lectures disque sont très lentes. Les durées absolues sont donc pessimistes (temps CPU de l'ordre de 0,1 s, temps réel de 10 à 20 s). Ce qui compte, ce sont les **rapports** entre variantes et la colonne CPU.

## Cause commune : les lignes `media` et `faces` sont énormes

- `media.print` (empreinte Vision) : 3 072 octets × 205 000 lignes, soit **630 Mo dans la table media**.
- `faces.print` : 3 072 octets × 114 000 lignes, soit **350 Mo dans la table faces**.
- La base fait 1,5 Go.

Toute requête qui lit la ligne elle-même (et pas un index couvrant) fait donc traverser des centaines de Mo au disque. C'est le cas d'un `SCAN media`, d'un `SCAN faces`, ou d'une jointure `JOIN media m ON m.id = …` par rowid. À froid (premier lancement), cela coûte plusieurs secondes.

---

## 1. Lancement : environ 5 s avant la grille

**Chemin exécuté** (`Model.swift:89-96`) : `loadRotations()`, puis `reloadGrid()`, puis `loaded = true`. Les deux étapes s'exécutent l'une après l'autre, avant le premier affichage.

| Étape | Requête | Plan | Mesure (copie) |
|---|---|---|---|
| `rotations()` `Browse.swift:452` | `WHERE rotate % 4 != 0` | **SCAN media** (table entière, 630 Mo d'empreintes) pour 397 lignes | 12 à 23 s réels / 0,14 s CPU |
| `mediaIdsAndYears(.all)` `Browse.swift:358` | jointure avec `folders`, filtre `dup_of IS NULL` | Le planificateur prend `folders` en boucle externe et l'index `media_folder_visible`. **Cet index ne contient pas `dup_of`**, donc chacune des 115 617 lignes est relue dans la table. | 15 à 22 s réels |
| La même requête avec `INDEXED BY media_visible` | | index couvrant (il contient `dup_of`) | **0,18 s** |

Hypothèse sur la régression depuis le « < 1 s » du 23 oct. : la v11 a ajouté le filtre `dup_of IS NULL`, et `dup_of` aussi à `media_visible`, mais **pas à `media_folder_visible`**. Avec la jointure `folders`, le planificateur a changé de chemin, et la grille relit désormais toute la table.

**Améliorations (gain / effort) :**
1. **Grille : forcer l'index couvrant.** Écrire `FROM media m INDEXED BY media_visible` (ou `CROSS JOIN` dans l'ordre media puis folders) dans `mediaIdsAndYears`, ou bien ajouter `dup_of` à `media_folder_visible` (migration v13). Gain mesuré : ×100 sur la requête (0,18 s). Effort : 1 ligne, ou 1 migration.
2. **Rotations : index partiel**, par exemple `CREATE INDEX media_rotated ON media(id, rotate) WHERE rotate % 4 != 0` (la requête doit reprendre exactement la même condition), ou bien les charger **après** `loaded = true` (les vignettes se redessinent via `thumbVersion`). Gain : supprime une lecture complète de la table avant l'affichage. Effort : très faible.
3. **Ensuite (cela ne bloque pas l'affichage, mais occupe l'acteur `Library`, qui sérialise toutes les requêtes) :** dans `stats()`, `unnamedFaces` et `ignoredFaces` (`Library.swift:405-406`) parcourent `faces` (environ 10 s réels chacune sur la copie). `labelled` (`count(DISTINCT media_id) FROM labels`) prend environ 1,5 s. `groupsNeedRebuild()` compte toutes les lignes `quick_hash` (0,5 s) ; un `EXISTS` suffirait. Un index couvrant sur faces (voir point 2) règle les deux premiers. Pour `labelled`, voir le point 3.

---

## 2. People : bascule Groups / « To identify »

**Chemin exécuté :** `IdentitiesView.load()` (`Identities.swift:426-453`). Cette fonction est relancée à **chaque** changement de `LoadKey` (mode Groups/Photos, Named / To identify / Ignored, année, `revision`). À chaque fois elle fait :

| Appel | Problème | Mesure (copie) |
|---|---|---|
| `identityCounts` `Identity.swift:97` | `SCAN faces` (avec les empreintes), puis lecture de `media` par rowid pour le filtre « visible » | 17,7 s réels |
| `duplicateOwners`, qui appelle `owners()` | `owners()` est calculé **deux fois** (`Identities.swift:433-434`). Chaque personne lance 3 sous-requêtes corrélées qui lisent `faces` et `media`. | environ 3 s ×2 |
| `identityToken` `Identity.swift:368` | `count(print)` force la **lecture de toutes les empreintes** (350 Mo), juste pour savoir s'il faut regrouper | 9,5 s |
| `identityClusters` `Identity.swift:63` | lit les 91 000 visages inconnus sans suggestion, avec jointure `media`, **trie tout** par `w*h` et ne garde que 5 000 empreintes. Ensuite vient le regroupement « leader », en O(5 000 × nb de leaders × 768), dans l'acteur `Library` : pendant ce temps, toutes les autres requêtes attendent. | 11,3 s (SQL seul) |

S'y ajoutent deux problèmes :
- `clusterKey` est un `@State` (`Identities.swift:37`) : il est perdu dès qu'on quitte People. Le regroupement est donc **recalculé à chaque retour** sur la page.
- Après chaque `identityEdit`, `refreshAll()` incrémente `revision`, ce qui relance tout le reste.

**Test sur la copie** avec les index `faces(person_id, ignored, suggested_person_id, media_id, w, h)` et `media(id, ignored, hidden, dup_of, meta_state, thumb_state, taken_at, aesthetic)`, utilisés via `INDEXED BY` :
- `identityCounts` : **11,9 s → 0,04 s**
- sélection des 5 000 visages à regrouper (identifiants seulement) : **6,4 s → 0,03 s**

Attention : sans `INDEXED BY` sur `media`, le planificateur continue de passer par le rowid et relit les lignes.

**Améliorations (gain / effort) :**
1. **Index couvrants sur `faces` et `media`**, comme ci-dessus (migration v13), et requêtes écrites pour les utiliser : `INDEXED BY`, ou une sous-requête `m.id IN (SELECT id FROM media INDEXED BY … WHERE visible)`. Pour le regroupement, sélectionner d'abord les 5 000 identifiants via l'index, puis lire **seulement leurs** empreintes (`WHERE id IN (…)`). Gain : environ ×100 à ×300 sur la partie SQL. Effort : faible à moyen.
2. **Rendre `identityToken` bon marché**, sans `count(print)` ni parcours de toute la table. Par exemple : `max(id)` + `total_changes`/`data_version`, ou des compteurs basés sur l'index. Supprimer aussi le double appel à `owners()` (`duplicateOwners` peut recevoir `o` en paramètre). Gain : environ 10 s réels à froid, et la moitié du temps de `owners`. Effort : faible.
3. **Mémoriser les groupes hors de la vue**, dans `AppModel` ou dans une table `face_clusters` recalculée en tâche de fond après une analyse ou une modification. Basculer ne relirait alors plus rien : seules les cases cochées changent l'affichage. Afficher les noms et les compteurs tout de suite, et les inconnus ensuite (chargement progressif). Gain : une bascule instantanée. Effort : moyen.

---

## 3. Ouverture de Labels

**Chemin exécuté :** `LabelsView`, `.task(id: model.revision)` (`App.swift:885`), qui appelle `labelSummaries()` (`Browse.swift:275`). Cette requête fait :
- un `UNION` (dédoublonnage par B-tree temporaire) entre les 1,38 M labels et les tags ;
- une jointure `media` par rowid, pour lire `aesthetic` et `taken_at` dans les grosses lignes ;
- deux fonctions de fenêtre (`count` et `row_number`), qui trient 1,38 M lignes.

Le tout pour obtenir 844 cartes. Et c'est relancé à **chaque** `revision`, donc toutes les 10 s pendant un scan, et après chaque modification.

| Variante | Mesure (copie) |
|---|---|
| actuelle | **21,1 s réels / 2,9 s CPU** |
| avec un index couvrant `media(id, ignored, hidden, aesthetic, taken_at, …)` | 4,4 s / 2,5 s CPU |
| idem + `UNION ALL` à la place de `UNION` | 2,6 s / 2,1 s CPU |
| simple `GROUP BY label` (les comptes seuls) | 1,5 s réels / 0,06 s CPU |

**Améliorations (gain / effort) :**
1. **Précalculer une table `label_info(label, n, cover_id)`**, sur le modèle de `group_info`, remplie par l'analyse ou l'import, ou mise à jour de façon incrémentale. L'ouverture de Labels devient alors un `SELECT` de 844 lignes (moins de 5 ms). Le même résumé sert à `searchVocabulary()` (0,9 à 1,5 s, lancé à chaque `refreshAll`) et à `stats.labelled`. Gain : maximal. Effort : moyen.
2. **Mesure intermédiaire bon marché :** `UNION ALL` à la place de `UNION` (la clé primaire de chaque table garantit déjà l'unicité ; seul un même mot présent à la fois en tag et en label serait compté deux fois), plus l'index couvrant sur `media` du point 2 (il sert aux deux). Gain : environ ×8 en temps réel ; le CPU reste autour de 2 s. Effort : faible.
3. **Mettre le résultat en cache dans `AppModel`**, avec une clé du type `count(*)`/`max(rowid)` de `labels` et `tags`, et ne plus recalculer à chaque `revision`. Afficher l'ancien résultat pendant le recalcul. Gain : seule la première ouverture coûte. Effort : faible.

---

## Priorités suggérées

1. **Lancement :** `INDEXED BY media_visible` dans la grille, et rotations chargées après l'affichage ou avec un index partiel. Deux lignes, environ 5 s → moins de 1 s attendu.
2. **Migration v13 avec deux index couvrants** (`faces` identité et `media` visibilité/esthétique). Elle accélère People, `stats()` et Labels d'un coup. Utiliser `INDEXED BY` dans les requêtes concernées et vérifier le plan avec `EXPLAIN QUERY PLAN`.
3. **Moins de recalculs :** `identityToken` léger, `owners()` appelé une seule fois, groupes et labels mémorisés hors des vues. Puis `label_info` précalculée.
4. **À plus long terme :** sortir les empreintes (`print`) des tables `media` et `faces` vers des tables à part (`media_print`, `face_print`). Chaque parcours de table redeviendrait alors léger, y compris ceux qu'on n'a pas encore repérés.

La copie de travail (`$TMPDIR/pn/lib.sqlite`) a reçu les index d'essai `x_faces_ident` et `x_media_vis`. La base réelle n'a pas été touchée.

---

## Correctifs appliqués (schéma v13)

- **Migration v13** (`Library.migrateV13`) :
  - `media_folder_visible` reçoit `dup_of` ;
  - nouveaux index : `media_rotated` (partiel), `media_visible_id`, `faces_ident` et `animals_ident` ;
  - table `label_info`, avec des déclencheurs qui la marquent périmée (`settings.label_info.dirty`) ;
  - `ANALYZE`.

  Elle s'exécute une seule fois, au premier lancement : 29 s réels sur la copie dans le bac à sable (2,5 s de CPU), probablement quelques secondes sur le Mac.
- **Lancement :** les rotations passent par l'index partiel. La grille utilise le nouvel index. Les filtres qui ne testent que `m.id` ou `m.taken_at` (personne, album, label, année, identités…) lisent media via `INDEXED BY media_visible`. `groupsNeedRebuild()` utilise `EXISTS`. `stats()` compte les visages en un seul passage sur `faces_ident`.
- **People / Animals :**
  - toutes les requêtes d'identité passent par `regionsOfVisible(k)` (`faces_ident`/`animals_ident` + `media_visible_id`) ;
  - `identityToken` ne lit plus les empreintes ;
  - `identityClusters` choisit les 5 000 identifiants sur les index, puis ne lit que leurs empreintes (`json_each`) ;
  - le regroupement « leader » calcule les scores contre tous les leaders en un seul produit matrice-vecteur (`vDSP_mmul`) ;
  - `owners()` n'est plus appelé deux fois (`Library.duplicateGroups`) ;
  - les groupes sont mis en cache dans `AppModel.clusters(…)` (clé = `identityToken`) et préparés après le premier `refreshAll`.
- **Labels :**
  - `label_info` est reconstruite si elle est périmée (`refreshLabelInfo`) à la fin des tâches d'indexation et au lancement ;
  - `LabelsView` affiche tout de suite les cartes en cache, puis les reconstruit si besoin, sauf pendant un scan ;
  - `searchVocabulary` et `stats.labelled` lisent la table précalculée ;
  - les comptes des cartes portent désormais sur les photos visibles, donc ils correspondent à la grille du label.

Mesures après correctifs (copie, binaire release, à froid → à chaud) :

| | à froid | à chaud |
|---|---|---|
| rotations | 0,001 s | 0,000 s |
| grille | 0,17 s | 0,08 s |
| stats | 0,7 s | 0,12 s |
| identityCounts | 0,08 s | 0,03 s |
| owners | 0,02 s | 0,02 s |
| regroupement visages | 2,1 s | 0,10 s (puis cache) |
| Labels (cartes) | < 1 ms (reconstruction : 1,5–5,6 s) | < 1 ms |
