# ClaudeMac

Une interface **native macOS** (SwiftUI) pour **Claude Code**, avec le choix du
LLM — modèles **Anthropic** *ou* modèles **locaux via Ollama** — et tous les
outils du CLI (Bash, Read, Edit, Grep, WebFetch, MCP, sous-agents…).

> ⚠️ Projet personnel, non affilié à Anthropic. Nécessite votre propre
> installation de [Claude Code](https://code.claude.com) (et votre propre
> authentification / clé API). Licence MIT.

L'app ne réimplémente rien : elle pilote le binaire `claude` en mode headless
(`--input-format stream-json`) et dessine une UI par-dessus. Tout ce que sait
faire Claude Code est donc disponible.

```
ClaudeMac.app (SwiftUI)
   │  stream-json (stdin/stdout)
   ▼
claude (CLI)  ──►  Anthropic          (modèles cloud, auth habituelle)
   │           └►  routeur local Node ──►  Ollama   (modèles locaux)
```

## Prérequis

- macOS 14+ et **Xcode / Swift 6** (`swift --version`)
- **Claude Code** installé et authentifié : `claude` dans le PATH
- **Node.js** (pour le routeur local, seulement si vous utilisez Ollama)
- **Ollama** (optionnel) : `ollama serve` + au moins un modèle `ollama pull qwen3:8b`

## Construire & lancer

```bash
./scripts/build.sh          # produit dist/ClaudeMac.app
./scripts/run.sh            # build + lance l'app
```

Le `.app` est signé ad-hoc pour se lancer localement sans souci Gatekeeper.

## Utilisation

1. **Nouvelle conversation** dans la sidebar.
2. **Modèle** : choisir un modèle Anthropic (Opus/Sonnet/Haiku/Fable) ou un
   modèle Ollama local (découverts automatiquement via `/api/tags`).
3. **Permissions** : mode d'exécution des outils (voir ci-dessous).
4. **Effort de raisonnement** : niveau `--effort` (Faible → Maximum) avec jauge
   à barres, visible aussi sous le composer. Plus haut = meilleure qualité mais
   plus lent / plus coûteux. Surtout utile pour les modèles Anthropic.
5. **Dossier de travail** : le répertoire où l'agent opère.
6. Écrire dans le composer, `Retour` pour envoyer.

### Pièces jointes

Bouton **trombone** ou **glisser-déposer** sur le composer :

- **Images** (png/jpg/gif/webp, ou HEIC/TIFF transcodés) → envoyées comme blocs
  image → vues par les modèles de vision (Anthropic, ou local ex. `qwen2.5vl`).
- **Fichiers texte / code** → contenu intégré directement dans le message
  (fonctionne avec n'importe quel modèle).
- **Autres fichiers** → référencés par chemin ; l'agent les ouvre avec l'outil
  Read au besoin.

### Instructions de codage (.md)

Sidebar → **Gérer les instructions**. Une bibliothèque de fichiers `.md`
(`~/Library/Application Support/ClaudeMac/instructions/`) que vous éditez dans
l'app. Les fichiers **activés** (cochés) sont concaténés et injectés via
`--append-system-prompt` : ils dirigent le style et les règles de codage sans
remplacer le prompt de Claude Code. Un fichier `directives-codage.md` est fourni.

### Historique des conversations

Chaque conversation est enregistrée (titre, date, transcript, coût) dans
`~/Library/Application Support/ClaudeMac/conversations/`. La section
**Historique** de la sidebar les liste ; un clic recharge le fil, et le message
suivant **reprend** la session (`--resume`). Clic droit → Supprimer.

### Modèle résident

Le routeur charge les modèles Ollama avec `keep_alive: -1` : ils **restent en
mémoire** tant que l'app tourne, et ne sont **déchargés qu'à la fermeture** de
ClaudeMac (les tours suivants sont donc instantanés, sans rechargement).

### Modèles locaux (Ollama)

Quand vous sélectionnez un modèle Ollama, l'app démarre automatiquement un petit
routeur Node (`router/anthropic-ollama-proxy.mjs`) qui **traduit l'API Anthropic
Messages vers `/api/chat` d'Ollama**, y compris les appels d'outils
(`tool_calls` ↔ `tool_use`) et le streaming. `claude` est pointé dessus via
`ANTHROPIC_BASE_URL`. La boucle d'outils complète de Claude Code fonctionne
alors sur un modèle local.

> Astuce : les modèles avec la capacité `tools` (ex. `qwen3-coder:30b`,
> `qwen3:8b`, `qwen3:14b`) sont nettement plus fiables pour l'usage agentique.
> Le « thinking » est désactivé par défaut côté routeur (relançable avec
> `--think`) pour un agent local plus réactif.

> **RAM / contexte** : le routeur borne `num_ctx` (défaut 16 384, réglable dans
> les préférences ⌘,). Sans ça, Ollama alloue le contexte **maximal du modèle**
> (jusqu'à 256k tokens → cache KV énorme). Exemple mesuré : `qwen3-coder:30b`
> passe de **45 Go à 20 Go** en bornant `num_ctx` à 16 384, largement suffisant
> pour le prompt de Claude Code (~4–5k tokens). Augmentez la valeur si vous
> voulez de longues conversations, au prix de plus de RAM.

### Modes de permission (v0.1)

| Mode | Effet |
|------|-------|
| **Tous les outils (bypass)** | Tout s'exécute sans confirmation. |
| **Éditions auto** | Les modifs de fichiers passent ; le reste attend le dialogue natif. |
| **Mode plan** | L'agent planifie sans rien exécuter. |
| **Demander (défaut)** | Les outils non autorisés sont refusés (dialogue natif à venir en v0.2). |

## Architecture

```
Sources/ClaudeMac/
├── App/              Point d'entrée SwiftUI + Settings scene
├── Models/           JSONValue, décodage stream-json, catalogue LLM, réglages
├── Engine/           ClaudeSession (pilote le CLI), BinaryLocator, Ollama,
│                     ModelRouter + RouterProcess (routeur local)
├── ViewModels/       ChatViewModel (orchestration, état de la conversation)
└── Views/            Sidebar, ChatView, MessageRow, ToolCallView, ModelPicker…
router/               Proxy Node Anthropic → Ollama
docs/                 Notes sur le protocole stream-json (confirmé vs incertain)
```

## Feuille de route (prochaines itérations)

- [ ] **Dialogue de permission natif** via le control protocol (`can_use_tool`)
- [ ] **Streaming token-par-token** (`--include-partial-messages`)
- [x] **Pièces jointes** (images vision + fichiers texte + référence par chemin)
- [x] **Bibliothèque d'instructions `.md`** (→ `--append-system-prompt`)
- [x] **Modèle résident** (`keep_alive: -1`, déchargé à la fermeture)
- [x] **Historique des conversations** (persistance + reprise via `--resume`)
- [x] **Contexte/tokens extensibles** (num_ctx jusqu'au max du modèle, num_predict)
- [x] **Découverte de serveurs Ollama** (scan local + réseau)
- [ ] Slash-commands et gestion visuelle des serveurs MCP
- [ ] Icône d'app + signature/notarisation pour distribution

## Notes

Le protocole `stream-json` du CLI est partiellement non documenté ; voir
[`docs/stream-json-protocol.md`](docs/stream-json-protocol.md) pour ce qui est
confirmé empiriquement sur la v2.1.201 vs les zones incertaines.

## Licence

[MIT](LICENSE). Les contributions (issues, PR) sont bienvenues. ClaudeMac est
un projet indépendant : « Claude » et « Claude Code » sont des marques
d'Anthropic ; cette app se contente de piloter le CLI officiel installé sur
votre machine.
