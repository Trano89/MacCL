# Protocole stream-json de `claude` — notes de référence

Cible : Claude Code **v2.1.201**. Le protocole `--input-format stream-json` est
**partiellement non documenté** (cf. GitHub anthropics/claude-code#24594). Ce
fichier distingue ce qui est **confirmé empiriquement** (capturé depuis ce repo)
de ce qui vient de sources communautaires (à valider).

## Lancement

```
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --verbose \
  --model <alias|nom> \
  --permission-mode <default|acceptEdits|plan|bypassPermissions|...> \
  [--include-partial-messages] \
  [--session-id <uuid> | --resume <uuid>]
```

Le process reste vivant en mode `--input-format stream-json` : on lui envoie une
ligne JSON par tour utilisateur sur stdin, il émet du NDJSON sur stdout.

## Événements stdout — CONFIRMÉ (capture réelle)

`system/init` a ses champs **à la racine** (PAS sous `data`) :

```json
{"type":"system","subtype":"init","cwd":"...","session_id":"...","model":"claude-haiku-4-5-20251001",
 "tools":[...],"mcp_servers":[...],"permissionMode":"default","slash_commands":[...],
 "apiKeySource":"none","claude_code_version":"2.1.201","agents":[...],"skills":[...],
 "output_style":"default","memory_paths":[...],"uuid":"..."}
```

`assistant` : `message` au format Anthropic (`content[]` de blocs `text` /
`thinking` / `tool_use`), + `parent_tool_use_id`, `session_id`, `uuid`.

`user` : `message.content[]` contient les blocs `tool_result`
(`tool_use_id`, `content`, `is_error`).

`result` :
```json
{"type":"result","subtype":"success|error_*","is_error":false,"result":"...",
 "total_cost_usd":0.0,"num_turns":1,"duration_ms":123,"usage":{...},
 "modelUsage":{...},"permission_denials":[...],"stop_reason":"...","session_id":"..."}
```

## Entrée utilisateur stdin — CONFIRMÉ

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}
```
`content` accepte aussi une string simple, ou un tableau avec des blocs `image`
(`source.type=base64`, `media_type`, `data`).

## Control protocol — SOURCES COMMUNAUTAIRES (à valider empiriquement)

Direction correcte : le **CLI** émet `control_request` sur SON stdout ; le
**client** répond par `control_response` sur le stdin du CLI.

Permission (mode `default`, si le client a annoncé la capacité `can_use_tool`) :
```json
// CLI -> client (stdout)
{"type":"control_request","request_id":"req_...",
 "request":{"subtype":"can_use_tool","tool_name":"Bash",
            "tool_use_id":"toolu_...","input":{...}}}
```
```json
// client -> CLI (stdin) : autoriser
{"type":"control_response","request_id":"req_...",
 "response":{"subtype":"success","request_id":"req_...",
             "response":{"behavior":"allow","updatedInput":{...}}}}
// refuser :
//   "response":{"behavior":"deny","message":"..."}
```

Interruption (client -> CLI, stdin) : `{"type":"interrupt"}` — pas de réponse
attendue, la session survit.

Sous-types de `control_request` qui exigeraient une réponse sous peine de
deadlock : `initialize`, `can_use_tool`, `hook_invoke`, `mcp_message`.

⚠️ **Incertitudes** : la nécessité (et le sens) du handshake `initialize`, le
double-emboîtement exact de `control_response`, et la syntaxe des permissions
permanentes ne sont pas confirmés pour v2.1.201. Stratégie retenue : v0.1 en
modes non-interactifs (aucun `control_request` émis), v0.2 avec réponse
défensive à **tout** `control_request` reçu.

## Streaming partiel — `--include-partial-messages`

```json
{"type":"stream_event","event":{"type":"content_block_delta","index":0,
 "delta":{"type":"text_delta","text":"..."}},"session_id":"...","uuid":"..."}
```
Deltas d'input outil : `delta.type=input_json_delta`, `partial_json`.
Les messages `assistant`/`user` complets arrivent **en plus** des partiels.
