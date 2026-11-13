# Valentin Entraîneur — ton Strava perso, sans le social

Appli iPhone de course à pied. Tout reste sur ton téléphone : pas de compte, pas de serveur, pas de fil d'actu.

## Ce qu'elle fait

- **Enregistrement GPS** qui continue écran verrouillé (point bleu en haut de l'écran pendant la course)
- **En direct** : temps, distance, allure instantanée et moyenne, pas, cadence, dénivelé, tracé sur la carte
- **Page « Général »** (cœur, tout à droite) : pas du jour, distance, temps en mouvement, heure par heure, 7 derniers jours, moyennes, record, distance de la semaine, courses du jour et l'historique de chaque journée. Ça vient du podomètre de l'iPhone : **ça compte même quand l'appli n'est pas ouverte**. L'iPhone ne garde que 7 jours d'historique, alors l'appli recopie les journées à chaque ouverture (et en arrière-plan quand iOS le permet). Il suffit de l'ouvrir au moins une fois par semaine pour ne rien perdre.
- **Pause / Reprendre / Terminer** — le temps et les pas pendant la pause ne sont pas comptés
- **Compteur de pas** : c'est le podomètre de l'iPhone (le même que l'app Santé) qui compte. À la fin de la course, le total exact est relu dans l'historique du téléphone. iOS demande l'accès « Mouvements et forme » la première fois.
- **Dénivelé mesuré au baromètre** de l'iPhone (comme Strava), bien plus précis que l'altitude GPS ; le GPS ne sert que de secours si le baromètre n'est pas disponible
- **Annonces vocales** à chaque kilomètre (temps total + temps du dernier km), la musique baisse le temps de l'annonce. Bouton haut-parleur pour couper.
- **Détail de chaque course** : carte du parcours, temps intermédiaires par km, profil d'altitude, dénivelé positif, pas, cadence et longueur de foulée, meilleurs efforts (1 km, 5 km, 10 km, semi, marathon), titre et notes modifiables
- **Revivre en 3D** (bouton sous la carte d'une course) : survol animé de ton parcours sur le relief (satellite ou plan), le point avance sur le tracé avec distance, temps, altitude, D+ et profil d'altitude
  - **Créer la vidéo** fabrique un fichier MP4 image par image : la vidéo est toujours fluide, même avec une connexion lente. Il faut garder l'appli ouverte pendant la création. Ensuite : **Dans Photos** ou **Partager**.
- **Course jamais perdue** : la course en cours est sauvegardée toutes les 20 secondes. Si l'appli se ferme (batterie, plantage), elle est récupérée au prochain lancement.
- **Historique** groupé par mois (glisser vers la gauche pour supprimer)
- **Stats** : totaux semaine / mois / année / tout, graphique des 12 dernières semaines, records personnels
- **Export GPX** (bouton partager dans le détail) si tu veux importer une course ailleurs

## Installer sur ton iPhone

Il faut un Mac avec **Xcode 16 ou plus récent** (gratuit sur l'App Store) et iOS 17+ sur l'iPhone.

1. Dézippe le dossier et double-clique sur `Foulee.xcodeproj`.
2. Dans Xcode : **Xcode › Settings › Accounts** → ajoute ton identifiant Apple (gratuit, pas besoin du programme développeur payant).
3. Clique sur le projet **Foulee** (colonne de gauche) → onglet **Signing & Capabilities** → choisis ton nom dans **Team**.
   - Si Xcode dit que l'identifiant est déjà pris, change `Bundle Identifier` (par ex. ajoute ton prénom à la fin).
4. Branche l'iPhone en USB, choisis-le en haut de la fenêtre Xcode, puis appuie sur **▶︎**.
5. Première fois seulement, sur l'iPhone :
   - **Réglages › Confidentialité et sécurité › Mode développeur** → activer (redémarrage).
   - **Réglages › Général › VPN et gestion de l'appareil** → fais confiance à ton profil développeur.
6. Ouvre Valentin Entraîneur et autorise la localisation (**« Lorsque l'app est active »** suffit).

### Bon à savoir

- Avec un compte Apple **gratuit**, l'appli doit être réinstallée depuis Xcode **tous les 7 jours** (tes courses sont conservées). Avec le programme développeur (99 $/an), c'est 1 an.
- Pour un GPS précis, attends que le voyant passe au **vert** avant de démarrer.
- Les courses sont stockées uniquement sur l'iPhone (et dans ta sauvegarde iCloud de l'appareil si elle est activée).

## Fichiers

| Fichier | Rôle |
|---|---|
| `FouleeApp.swift` | Point d'entrée, onglets |
| `RunTracker.swift` | GPS, distance, dénivelé, allure, pas, voix, sauvegarde de secours |
| `Models.swift` | Données d'une course (SwiftData) |
| `Analysis.swift` | Meilleurs efforts, export GPX, formats d'affichage |
| `RecordView.swift` | Écran d'enregistrement |
| `HistoryView.swift` | Liste des courses |
| `RunDetailView.swift` | Détail d'une course |
| `StatsView.swift` | Statistiques et records |
| `TodayView.swift` | Page « Général » |
| `Activity.swift` | Podomètre, temps en mouvement, archive des journées |
| `FlyoverView.swift` | Écran du survol 3D |
| `FlyoverEngine.swift` | Trajectoire de la caméra et déroulé du survol |
| `FlyoverMap.swift` | Carte 3D (tracé, point, caméra) |
| `VideoExporter.swift` | Création de la vidéo image par image |
| `VideoResultView.swift` | Aperçu, enregistrement et partage de la vidéo |
