# Lumifolio

Une app native (SwiftUI + SwiftData) pour gérer sa collection de cartes Pokémon, sur iPhone, iPad et Mac.

Les données des cartes (images, extensions, séries, prix) viennent de l'API gratuite [TCGdex](https://tcgdex.dev), en français.

## Installer

**Mac (macOS 14 ou plus récent)**
1. Télécharge `Lumifolio-mac.zip` dans la page [Releases](../../releases) et décompresse-le.
2. Glisse `Lumifolio` dans le dossier Applications, puis ouvre-la.
3. macOS indique que l'app vient d'un développeur non identifié (elle n'est pas validée par Apple, ce qui demande un compte payant) : ouvre **Réglages Système › Confidentialité et sécurité**, puis clique **Ouvrir quand même** en bas de la page. À faire une seule fois.

**iPhone / iPad (iOS 17 ou plus récent)**
Apple ne permet pas de distribuer une app hors App Store sans compte développeur payant. Pour l'installer, il faut la compiler soi-même avec un Mac (voir « Compiler » plus bas) ; avec un Apple ID gratuit, l'app est à réinstaller tous les 7 jours.

**Android**
Version en préparation.

## Fonctions

**Collection**
- Grille de tes cartes, tri (récentes, nom, valeur…), filtres (holo / reverse, doublons, classeurs perso).
- Bandeau : nombre de cartes, valeur estimée, plus-value par rapport au prix payé.
- Carte vedette (la plus chère, au hasard ou épinglée), objectifs de complétion d'extensions.
- Succès à débloquer, mode vitrine (diaporama plein écran), statistiques et historique de la valeur.

**Fiche d'une carte**
- Variante, état, langue, quantité, prix payé, tampon (Prerelease, Staff, logo de l'extension…).
- Carte gradée (PSA, CGC, PCA, BGS, CCC) avec note et valeur estimée.
- Courbe de l'évolution du prix, photo personnelle (proposée d'office quand la carte n'a pas d'image en ligne), classeurs perso.
- Visionneuse plein écran avec effet holo qui suit l'inclinaison du téléphone.
- Partage de la carte en image stylée (1080 × 1350).

**Recherche, extensions, wishlist**
- Recherche par nom en français ou par numéro (« 49/100 », « SVP 85 »), filtres avancés (rareté, type, illustrateur), scan du numéro de carte à l'appareil photo (iPhone).
- Extensions regroupées par série, progression, vue grille ou classeur, ajout de plusieurs cartes d'un coup.
- Wishlist avec prix cible et alerte « Bon prix ».

**Données**
- Fonctionne hors connexion (images enregistrées sur l'appareil).
- Export / import JSON, sauvegarde automatique quotidienne dans un dossier choisi (iCloud Drive conseillé), avec les 7 dernières versions gardées.

## Prix : d'où ils viennent

- **Cote** : prix « trend » Cardmarket fourni par TCGdex. Il mélange toutes les langues et tous les pays de vendeurs (Cardmarket ne publie pas de cote par langue).
- **Reverse** et versions **tamponnées** : prix propre de la version quand TCGdex le fournit ; pour les anciennes cartes tamponnées « logo de l'extension », prix reverse de la carte.
- **1ère édition** : cote Cardmarket × écart 1ère édition / illimitée observé sur TCGplayer (marché US).
- **État** : estimation, en part de la cote Near Mint : Mint / Near Mint 100 %, Excellent 80 %, Bon état 60 %, Légèrement joué 45 %, Joué 30 %, Mauvais 15 %. Paliers repris de [ValueMyCards](https://valuemycards.com/trainer-tips/how-we-determine-prices) (moyenne des annonces Troll and Toad), « Légèrement joué » et « Mauvais » interpolés.
- **Carte gradée** : la valeur saisie à la main remplace la cote.

## Compiler

Prérequis : Xcode 16 ou plus récent. Cibles minimales : iOS 17 / macOS 14.

1. Ouvre `Classeur.xcodeproj`.
2. Cible **Classeur** → **Signing & Capabilities** → choisis ton équipe (un Apple ID gratuit suffit).
3. Si l'identifiant `app.lumifolio` est refusé, remplace-le par un identifiant à toi.
4. Choisis **My Mac** ou ton iPhone branché, puis **Run** (▶).

Avec un compte Apple gratuit, l'app installée sur iPhone expire au bout de 7 jours : il suffit de relancer **Run** pour la réinstaller.

## Organisation du code

| Fichier | Contenu |
|---|---|
| `ClasseurApp.swift` | Point d'entrée, onglets, thème (couleurs, fond nuit, bandeau holo), vignettes de cartes |
| `Models.swift` | Modèles SwiftData (`OwnedCard`, `ValueSnapshot`), valeur, plus-value, historique de prix, décote selon l'état |
| `TCGdex.swift` | Client de l'API TCGdex, prix Cardmarket / TCGplayer, versions tamponnées, regroupement par série |
| `CollectionViews.swift` | Collection, wishlist, fiche d'une carte possédée |
| `BrowseViews.swift` | Recherche, fiche d'une carte, extensions, ajout en lot |
| `Premium.swift` | Plus-value, gradation, historique, partage en image, succès, vitrine, classeurs perso |
| `Extras.swift` | Statistiques, vue classeur, visionneuse holo, mise à jour des prix, carte vedette, objectifs |
| `Transfer.swift` | Export / import JSON, sauvegarde automatique |
| `Scanner.swift` | Scan du numéro de carte (VisionKit, iPhone) |
| `ImageLoader.swift` | Chargement et cache des images, détection des images manquantes |

## Licence

Application gratuite, **tous droits réservés** : tu peux la télécharger et l'utiliser librement, mais pas copier, modifier ni redistribuer son code. Détails dans [LICENSE](LICENSE).

## Mentions

Pokémon et les noms associés sont des marques de Nintendo, Creatures Inc. et GAME FREAK inc. Ce projet n'est ni affilié ni approuvé par eux. Données de cartes : TCGdex.
