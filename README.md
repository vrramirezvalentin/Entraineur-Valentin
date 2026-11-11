# Valentin Entraîneur — ton Strava perso, sans le social

Appli iPhone de course à pied. Tout reste sur ton téléphone : pas de compte, pas de serveur, pas de fil d'actu.

## Ce qu'elle fait

- **Enregistrement GPS** qui continue écran verrouillé (point bleu en haut de l'écran pendant la course)
- **En direct** : temps, distance, allure instantanée et moyenne, tracé sur la carte
- **Pause / Reprendre / Terminer** — le temps de pause n'est pas compté
- **Annonces vocales** à chaque kilomètre (temps total + temps du dernier km), la musique baisse le temps de l'annonce. Bouton haut-parleur pour couper.
- **Détail de chaque course** : carte du parcours, temps intermédiaires par km, profil d'altitude, dénivelé positif, meilleurs efforts (1 km, 5 km, 10 km, semi, marathon), titre et notes modifiables
- **Revivre en 3D** (bouton sous la carte d'une course) : survol animé de ton parcours sur le relief (satellite ou plan), le point avance sur le tracé avec distance, temps, altitude, D+ et profil d'altitude en direct
  - **Créer la vidéo** enregistre le survol (iOS demande l'autorisation la 1re fois), puis tu peux la mettre dans **Photos** ou la **partager**
  - Astuce : fais un « Rejouer » avant, pour que le relief soit déjà chargé quand tu enregistres
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
| `RunTracker.swift` | GPS, calcul distance/dénivelé/allure, km, voix |
| `Models.swift` | Données d'une course (SwiftData) |
| `Analysis.swift` | Meilleurs efforts, export GPX, formats d'affichage |
| `RecordView.swift` | Écran d'enregistrement |
| `HistoryView.swift` | Liste des courses |
| `RunDetailView.swift` | Détail d'une course |
| `StatsView.swift` | Statistiques et records |
| `FlyoverView.swift` | Survol 3D animé et export vidéo |
