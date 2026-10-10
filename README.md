# Radar des Cotes

Robot qui repère les paris football à valeur positive sur 1xBet (comparés à Pinnacle sans marge), propose un combiné de cote 2,5 ou plus composé de favoris, prévient sur Telegram et suit les résultats des paris.

## Fonctionnement

- **GitHub Actions** lance `radar.ps1` toutes les 15 minutes : lecture des messages Telegram, et toutes les 2 heures de 8 h à 22 h (heure de Paris) analyse des cotes via The Odds API.
- **Telegram** : alertes de combiné (cotes vérifiées en direct), résultats des paris, commandes `/top`, `/paris`, `/bankroll 80`, `/gagne 3`, `/perdu 3`, `/rembourse 3`, `/auto 3`, `/supprime 3`.
- **GitHub Pages** (dossier `docs`) : l'application web, avec le Top 10, les alertes, « Mes paris » et les outils d'analyse.

## Réglages

Secrets du dépôt (Settings → Secrets and variables → Actions) :

- `ODDS_API_KEY` : clé The Odds API (offre gratuite : 500 requêtes par mois).
- `TELEGRAM_TOKEN` : code du robot donné par @BotFather.

Le premier compte Telegram qui écrit au robot en devient le propriétaire.

Les réglages de l'analyse (championnats, seuil de valeur, cote du combiné…) sont en haut de `radar.ps1`.

## Fichiers

- `radar.ps1` : le robot.
- `.github/workflows/radar.yml` : la planification.
- `docs/index.html` : l'application web ; `docs/data/*.json` : les données qu'elle affiche.
- `etat/` : la mémoire du robot (paris, alertes, cotes en cache).

Ne misez que ce que vous pouvez vous permettre de perdre. Aucun calcul ne garantit un gain.
