#!/usr/bin/env node
// Anthropic Messages API  ->  Ollama /api/chat  translation proxy.
//
// Lets `claude` (which speaks the Anthropic Messages API) drive local Ollama
// models. Point Claude Code at it with:
//   ANTHROPIC_BASE_URL=http://127.0.0.1:<port>
//   ANTHROPIC_MODEL=<ollama model name>
//
// Usage: node anthropic-ollama-proxy.mjs --port 8787 --ollama http://localhost:11434
import http from 'node:http'
import crypto from 'node:crypto'

const args = process.argv.slice(2)
function argOf(flag, def) {
  const i = args.indexOf(flag)
  return i >= 0 && args[i + 1] ? args[i + 1] : def
}
const PORT = parseInt(argOf('--port', process.env.PORT || '8787'), 10)
const OLLAMA = (argOf('--ollama', process.env.OLLAMA_BASE_URL || 'http://localhost:11434')).replace(/\/$/, '')
// Thinking is off by default: for the agentic tool loop it mostly wastes the
// token budget (we don't surface it), and can starve `content`. Enable with --think.
const THINK = args.includes('--think')
// Bound the context window. Without this, Ollama uses the model's Modelfile
// default (often very large, e.g. 40960 or 262144), which allocates a huge KV
// cache and balloons RAM. This value must still fit Claude Code's system prompt
// + tool schemas. Override with --ctx or OLLAMA_NUM_CTX.
// Grows dynamically when conversations exceed the initial budget — see fetchOllama.
let CTX = parseInt(argOf('--ctx', process.env.OLLAMA_NUM_CTX || '16384'), 10)
// Keep the model resident in memory. -1 = never unload (the app unloads it on
// quit). Override with --keep-alive (e.g. "5m", "0", "-1").
const KEEP_ALIVE_RAW = argOf('--keep-alive', process.env.OLLAMA_KEEP_ALIVE || '-1')
const KEEP_ALIVE = Number.isNaN(Number(KEEP_ALIVE_RAW)) ? KEEP_ALIVE_RAW : Number(KEEP_ALIVE_RAW)
// Max output tokens (num_predict). 0 = follow the client's max_tokens,
// -1 = unlimited (generate until stop or the context fills). Bounded by CTX.
const MAX_PREDICT = parseInt(argOf('--max-predict', process.env.OLLAMA_MAX_PREDICT || '0'), 10)
// Ghost-work watchdog: after this much stream inactivity, probe the server and
// abort the turn if it's gone (see handleMessages). Override with --stall (ms).
const STALL_MS = Math.max(5_000, parseInt(argOf('--stall', process.env.OLLAMA_STALL_MS || '60000'), 10))

const log = (...a) => console.error('[router]', ...a)
const rid = (p) => p + crypto.randomBytes(12).toString('hex')

// ---- Anthropic -> Ollama request translation ---------------------------------

function textFromAnthropicContent(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.filter(b => b?.type === 'text').map(b => b.text).join('\n')
}

function systemToString(system) {
  if (!system) return ''
  if (typeof system === 'string') return system
  if (Array.isArray(system)) return system.map(b => b?.text ?? '').join('\n')
  return ''
}

// Map Anthropic messages[] -> Ollama messages[]
function toOllamaMessages(system, messages) {
  const out = []
  const sys = systemToString(system)
  if (sys) out.push({ role: 'system', content: sys })

  for (const m of messages || []) {
    const role = m.role
    const content = m.content
    if (typeof content === 'string') {
      out.push({ role, content })
      continue
    }
    if (!Array.isArray(content)) continue

    // Assistant messages may carry text + tool_use blocks.
    if (role === 'assistant') {
      const text = content.filter(b => b.type === 'text').map(b => b.text).join('\n')
      const toolUses = content.filter(b => b.type === 'tool_use')
      const msg = { role: 'assistant', content: text }
      if (toolUses.length) {
        msg.tool_calls = toolUses.map(t => ({
          function: { name: t.name, arguments: t.input ?? {} },
        }))
      }
      out.push(msg)
      continue
    }

    // User messages may carry text, images, and tool_result blocks.
    const texts = []
    const images = []
    const toolResults = []
    for (const b of content) {
      if (b.type === 'text') texts.push(b.text)
      else if (b.type === 'image' && b.source?.type === 'base64') images.push(b.source.data)
      else if (b.type === 'tool_result') toolResults.push(b)
    }
    // Emit tool results first as role:"tool" messages, then any user text.
    for (const tr of toolResults) {
      let c = tr.content
      if (Array.isArray(c)) c = c.map(x => (typeof x === 'string' ? x : x?.text ?? '')).join('\n')
      out.push({ role: 'tool', content: String(c ?? ''), tool_name: tr.tool_use_id })
    }
    if (texts.length || images.length) {
      const msg = { role: 'user', content: texts.join('\n') }
      if (images.length) msg.images = images
      out.push(msg)
    }
  }
  return out
}

function toOllamaTools(tools) {
  if (!Array.isArray(tools) || !tools.length) return undefined
  return tools
    .filter(t => t && t.name)
    .map(t => ({
      type: 'function',
      function: {
        name: t.name,
        description: t.description ?? '',
        parameters: t.input_schema ?? { type: 'object', properties: {} },
      },
    }))
}

// ---- SSE helpers (Anthropic streaming format) --------------------------------

function sse(res, event, data) {
  res.write(`event: ${event}\n`)
  res.write(`data: ${JSON.stringify(data)}\n\n`)
}

// ---- Core handler ------------------------------------------------------------

async function handleMessages(reqBody, res) {
  const body = JSON.parse(reqBody || '{}')
  const model = body.model || 'llama3'
  const stream = body.stream !== false
  // Did the client (claude) request extended thinking? It does so at higher
  // --effort. We tie Ollama's thinking to that: think only when asked, and only
  // then emit a thinking block back — so we never send unrequested thinking.
  const clientThinking = !!(body.thinking && body.thinking.type && body.thinking.type !== 'disabled')
  const ollamaBody = {
    model,
    messages: toOllamaMessages(body.system, body.messages),
    stream,
    think: clientThinking || THINK,
    keep_alive: KEEP_ALIVE,
    options: { num_ctx: CTX }, // CTX grows dynamically on context overflow retry
  }
  const tools = toOllamaTools(body.tools)
  if (tools) ollamaBody.tools = tools
  // Max output tokens. -1 = unlimited; else follow the override or client, capped
  // by the context window so Ollama doesn't over-reserve memory.
  if (MAX_PREDICT === -1) {
    ollamaBody.options.num_predict = -1
  } else {
    const wantPredict = MAX_PREDICT > 0 ? MAX_PREDICT
      : (typeof body.max_tokens === 'number' ? body.max_tokens : 4096)
    ollamaBody.options.num_predict = Math.min(wantPredict, CTX)
  }
  if (typeof body.temperature === 'number') ollamaBody.options.temperature = body.temperature
  if (typeof body.top_p === 'number') ollamaBody.options.top_p = body.top_p

  const promptTokens = Math.ceil(JSON.stringify(ollamaBody.messages).length / 4)
  log(`req model=${model} ~${promptTokens} tok · num_ctx=${CTX} · tools=${(ollamaBody.tools || []).length} · clientThinking=${clientThinking}`)

  const msgId = rid('msg_')

  // Non-streaming path: one JSON response once Ollama replies.
  if (!stream) {
    let upstream
    try { upstream = await fetchOllama(ollamaBody) }
    catch (e) { return sendError(res, false, e.message) }
    return handleNonStream(upstream, res, msgId, model)
  }

  // Streaming path: open the SSE channel and start pinging IMMEDIATELY, BEFORE
  // touching Ollama. A large model can take minutes to cold-load (a 30B can eat
  // ~45 GB!); without an early response + keepalive pings the client times out
  // waiting for the first byte. This was the "timeout, nothing generated" bug.
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  })
  sse(res, 'message_start', {
    type: 'message_start',
    message: {
      id: msgId, type: 'message', role: 'assistant', model,
      content: [], stop_reason: null, stop_sequence: null,
      usage: { input_tokens: 0, output_tokens: 0 },
    },
  })
  let pinger = setInterval(() => { try { sse(res, 'ping', { type: 'ping' }) } catch {} }, 4000)

  // Ghost-work watchdog. Our keepalive pings keep claude waiting forever, so a
  // dead Ollama stream (remote machine asleep, runner crashed, network drop
  // without RST) would look like "still working" indefinitely. Track stream
  // activity; when it stalls, probe the server and abort with a visible error.
  const controller = new AbortController()
  let lastActivity = Date.now()
  let bodyStarted = false
  let stalled = null // reason string when the watchdog aborted
  let probing = false
  const stallTimer = setInterval(async () => {
    if (probing || stalled) return
    const idle = Date.now() - lastActivity
    if (idle < STALL_MS) return
    probing = true
    // Is the model resident? That's what separates a legitimate long wait from a
    // lost request: while a model cold-loads it is absent from /api/ps, and that
    // can take minutes. Once it IS loaded, silence means our stream is dead (the
    // usual cause: the TCP connection died — VPN hiccup — so the request never
    // reaches Ollama, which happily answers everyone else).
    const loaded = await modelStillRunning(ollamaBody.model)
    const reachable = loaded ? true : await serverReachable()
    probing = false
    const idleNow = Date.now() - lastActivity
    const secs = Math.round(idleNow / 1000)

    if (!reachable) {
      stalled = `le serveur Ollama ne répond plus (${secs}s sans données)`
    } else if (!loaded && !bodyStarted) {
      // Cold load in progress — be patient, but not forever.
      if (idleNow > STALL_MS * 10) stalled = `le modèle n'a pas fini de charger (${secs}s)`
    } else if (idleNow > STALL_MS * 2) {
      // Model resident but our stream is silent → the request is lost.
      stalled = bodyStarted
        ? `génération interrompue (${secs}s sans données, modèle toujours chargé)`
        : `requête perdue (${secs}s sans réponse alors que le modèle est chargé et le serveur répond)`
    }

    if (stalled) {
      log(`stall: ${stalled} — abandon du tour`)
      controller.abort()
    } else {
      log(`watchdog: ${secs}s d'inactivité (chargé=${loaded}, flux démarré=${bodyStarted}) — on patiente`)
    }
  }, 10_000)

  const stopPing = () => {
    if (pinger) { clearInterval(pinger); pinger = null }
    clearInterval(stallTimer)
  }
  // Client gone (interrupt, app quit): stop wasting the backend too.
  res.on('close', () => { stopPing(); controller.abort() })

  let upstream
  try {
    upstream = await fetchOllama(ollamaBody, controller.signal)
  } catch (e) {
    stopPing()
    return emitStreamError(res, stalled ? `Travail interrompu : ${stalled}.` : e.message)
  }

  // Buffer the whole turn, then emit content blocks. Buffering lets us recover
  // tool calls that a local model emitted as TEXT (```json / <tool_call> / bare
  // JSON) instead of native tool_calls — common with code models. Keepalive
  // pings above keep the client's connection warm while we buffer.
  const toolNames = new Set((body.tools || []).map((t) => t && t.name).filter(Boolean))
  let contentText = ''
  const nativeCalls = []
  let stopReason = 'end_turn'
  let outTokens = 0
  let inTokens = 0

  // Thinking is streamed LIVE (it never carries tool calls, so it doesn't need
  // the buffering below) — otherwise long reasoning looks like a frozen app.
  let index = -1
  let thinkingOpen = false
  const closeThinking = () => {
    if (!thinkingOpen) return
    sse(res, 'content_block_delta', {
      type: 'content_block_delta', index,
      delta: { type: 'signature_delta', signature: 'bG9jYWwtcm91dGVy' },
    })
    sse(res, 'content_block_stop', { type: 'content_block_stop', index })
    thinkingOpen = false
  }

  let buf = ''
  const decoder = new TextDecoder()
  // Track whether Ollama sent a proper `done` signal. If the stream ends without it,
  // the connection was likely dropped (network interruption, server crash). We must emit
  // an error instead of message_stop so claude Code doesn't treat partial content as complete.
  let gotDone = false
  try {
    for await (const chunk of upstream.body) {
      lastActivity = Date.now()
      bodyStarted = true
      buf += decoder.decode(chunk, { stream: true })
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (!line) continue
        let obj
        try { obj = JSON.parse(line) } catch { continue }

        const m = obj.message || {}
        if (typeof m.thinking === 'string' && m.thinking.length && (clientThinking || THINK)) {
          if (!thinkingOpen) {
            index += 1
            sse(res, 'content_block_start', {
              type: 'content_block_start', index,
              content_block: { type: 'thinking', thinking: '' },
            })
            thinkingOpen = true
          }
          sse(res, 'content_block_delta', {
            type: 'content_block_delta', index,
            delta: { type: 'thinking_delta', thinking: m.thinking },
          })
        }
        if (typeof m.content === 'string' && m.content.length) {
          closeThinking()
          contentText += m.content
        }
        if (Array.isArray(m.tool_calls)) {
          for (const tc of m.tool_calls) {
            const fn = tc.function || {}
            nativeCalls.push({
              name: fn.name,
              args: typeof fn.arguments === 'string' ? safeParse(fn.arguments) : (fn.arguments ?? {}),
            })
          }
        }
        if (obj.done) {
          gotDone = true
          if (typeof obj.prompt_eval_count === 'number') inTokens = obj.prompt_eval_count
          if (typeof obj.eval_count === 'number') outTokens = obj.eval_count
          if (obj.done_reason === 'length') stopReason = 'max_tokens'
        }
      }
    }
  } catch (e) {
    log('stream error', e.message)
  }

  // If the stream ended without a `done` signal, Ollama's connection was dropped
  // mid-turn (or our stall watchdog aborted it). Emit an error so claude Code
  // doesn't treat partial content as valid output.
  if (!gotDone) {
    const reason = stalled
      ? `⚠️ Travail interrompu : ${stalled}. Vérifiez le serveur Ollama (machine allumée, \`ollama serve\` actif) puis renvoyez votre message.`
      : '⚠️ Connexion Ollama interrompue — le serveur a fermé la connexion sans signal de terminaison.'
    log('Ollama stream ended without done — ' + (stalled || 'connection likely dropped'))
    stopPing()
    sse(res, 'content_block_start', {
      type: 'content_block_start', index: (index >= -1 ? index + 1 : 0),
      content_block: { type: 'text', text: '' },
    })
    sse(res, 'content_block_delta', {
      type: 'content_block_delta', index: (index >= -1 ? index + 1 : 0),
      delta: { type: 'text_delta', text: reason },
    })
    sse(res, 'content_block_stop', { type: 'content_block_stop', index: (index >= -1 ? index + 1 : 0) })
    sse(res, 'message_delta', {
      type: 'message_delta',
      delta: { stop_reason: 'error', stop_sequence: null },
      usage: { input_tokens: inTokens, output_tokens: outTokens },
    })
    sse(res, 'message_stop', { type: 'message_stop' })
    res.end()
    return  // do NOT fall through to normal completion
  }

  stopPing()
  closeThinking()

  // Prefer native tool calls; otherwise try to recover them from the text.
  let toolCalls = nativeCalls
  let text = contentText
  if (toolCalls.length === 0) {
    const recovered = extractToolCalls(contentText, toolNames)
    if (recovered.length) {
      toolCalls = recovered
      text = stripToolCallText(contentText)
      log(`recovered ${recovered.length} tool call(s) from text: ${recovered.map((c) => c.name).join(', ')}`)
    }
  }

  const trimmed = text.trim()
  if (trimmed) {
    index += 1
    sse(res, 'content_block_start', { type: 'content_block_start', index, content_block: { type: 'text', text: '' } })
    sse(res, 'content_block_delta', { type: 'content_block_delta', index, delta: { type: 'text_delta', text } })
    sse(res, 'content_block_stop', { type: 'content_block_stop', index })
  }
  for (const call of toolCalls) {
    index += 1
    sse(res, 'content_block_start', {
      type: 'content_block_start', index,
      content_block: { type: 'tool_use', id: rid('toolu_'), name: call.name, input: {} },
    })
    sse(res, 'content_block_delta', {
      type: 'content_block_delta', index,
      delta: { type: 'input_json_delta', partial_json: JSON.stringify(call.args || {}) },
    })
    sse(res, 'content_block_stop', { type: 'content_block_stop', index })
  }
  if (toolCalls.length) stopReason = 'tool_use'

  sse(res, 'message_delta', {
    type: 'message_delta',
    delta: { stop_reason: stopReason, stop_sequence: null },
    usage: { input_tokens: inTokens, output_tokens: outTokens },
  })
  sse(res, 'message_stop', { type: 'message_stop' })
  res.end()
}

// Recover tool calls a model emitted as text. Only accepts objects whose name
// matches a tool the client actually provided (avoids false positives).
function extractToolCalls(text, toolNames) {
  if (!text || !toolNames || toolNames.size === 0) return []
  const calls = []
  const seen = new Set()
  const consider = (raw) => {
    const obj = typeof raw === 'string' ? safeParse(raw) : raw
    if (!obj || typeof obj !== 'object') return
    for (const o of Array.isArray(obj) ? obj : [obj]) {
      if (!o || typeof o !== 'object') continue
      const name = o.name || o.tool || o.tool_name || (o.function && o.function.name)
      let args = o.arguments ?? o.parameters ?? o.input ?? (o.function && o.function.arguments) ?? {}
      if (typeof args === 'string') args = safeParse(args)
      if (name && toolNames.has(name)) {
        const key = name + '|' + JSON.stringify(args)
        if (!seen.has(key)) { seen.add(key); calls.push({ name, args: args && typeof args === 'object' ? args : {} }) }
      }
    }
  }
  consider(text.trim())                                             // whole content is JSON
  let m
  const tagRe = /<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/g
  while ((m = tagRe.exec(text))) {
    const parsed = typeof m[1] === 'string' ? safeParse(m[1]) : m[1]
    if (parsed && typeof parsed === 'object' && parsed.name && toolNames.has(parsed.name) &&
          (parsed.arguments ?? parsed.parameters ?? parsed.input ?? parsed.function)) {
      consider(parsed)
    }
  }
  const fenceRe = /```(?:json|tool_call)?\s*([\s\S]*?)```/g
  while ((m = fenceRe.exec(text))) {
    const parsed = typeof m[1] === 'string' ? safeParse(m[1]) : m[1]
    if (parsed && typeof parsed === 'object' && parsed.name && toolNames.has(parsed.name) &&
          (parsed.arguments ?? parsed.parameters ?? parsed.input ?? parsed.function)) {
      consider(parsed)
    }
  }
  return calls
}

function stripToolCallText(text) {
  return String(text)
    .replace(/<tool_call>[\s\S]*?<\/tool_call>/g, '')
    .replace(/```(?:json|tool_call)?\s*[\s\S]*?```/g, '')
    .trim()
}

// message_start has already been sent; surface an error as a visible text block.
function emitStreamError(res, message) {
  sse(res, 'content_block_start', {
    type: 'content_block_start', index: 0,
    content_block: { type: 'text', text: '' },
  })
  sse(res, 'content_block_delta', {
    type: 'content_block_delta', index: 0,
    delta: { type: 'text_delta', text: `⚠️ ${message}` },
  })
  sse(res, 'content_block_stop', { type: 'content_block_stop', index: 0 })
  sse(res, 'message_delta', {
    type: 'message_delta',
    delta: { stop_reason: 'end_turn', stop_sequence: null },
    usage: { input_tokens: 0, output_tokens: 0 },
  })
  sse(res, 'message_stop', { type: 'message_stop' })
  res.end()
}

async function handleNonStream(upstream, res, msgId, model) {
  const data = await upstream.json().catch(() => ({}))
  const m = data.message || {}
  const content = []
  if (m.content) content.push({ type: 'text', text: m.content })
  if (Array.isArray(m.tool_calls)) {
    for (const tc of m.tool_calls) {
      const fn = tc.function || {}
      content.push({
        type: 'tool_use', id: rid('toolu_'), name: fn.name,
        input: typeof fn.arguments === 'string' ? safeParse(fn.arguments) : (fn.arguments ?? {}),
      })
    }
  }
  const payload = {
    id: msgId, type: 'message', role: 'assistant', model, content,
    stop_reason: Array.isArray(m.tool_calls) && m.tool_calls.length ? 'tool_use' : 'end_turn',
    stop_sequence: null,
    usage: { input_tokens: data.prompt_eval_count ?? 0, output_tokens: data.eval_count ?? 0 },
  }
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify(payload))
}

function safeParse(s) { try { return JSON.parse(s) } catch { return {} } }

// Quick health probes used by the stall watchdog.
async function serverReachable() {
  try {
    const r = await fetch(`${OLLAMA}/api/tags`, { signal: AbortSignal.timeout(5000) })
    return r.ok
  } catch { return false }
}

async function modelStillRunning(model) {
  try {
    const r = await fetch(`${OLLAMA}/api/ps`, { signal: AbortSignal.timeout(5000) })
    if (!r.ok) return false
    const d = await r.json().catch(() => null)
    return ((d && d.models) || []).some((m) => m.name === model || m.model === model)
  } catch { return false }
}

// Call Ollama, retrying without `think` for models that reject it. The caller's
// AbortSignal (stall watchdog / client disconnect) governs cancellation — no
// blanket timeout here, long legitimate generations must survive.
async function fetchOllama(ollamaBody, signal) {
  const url = `${OLLAMA}/api/chat`
  const post = (b) => {
    const opts = {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(b),
    }
    if (signal) opts.signal = signal
    return fetch(url, opts)
  }

  let resp
  try {
    resp = await post(ollamaBody)
  } catch (e) {
    throw new Error(`Ollama injoignable à ${OLLAMA} : ${e.message}`)
  }
  if (resp.ok) return resp
  const txt = await resp.text().catch(() => '')

  // Conversation grew past num_ctx → grow the window and retry instead of failing
  // ("request (N tokens) exceeds the available context size (M)").
  const overflow = txt.match(/\((\d+) tokens\) exceeds the available context size/)
  if (overflow) {
    const needed = parseInt(overflow[1], 10)
    const newCtx = Math.min(Math.ceil((needed + 8192) / 4096) * 4096, 262144)
    if (newCtx > CTX) {
      log(`contexte dépassé (${needed} tokens) — expansion CTX ${CTX} → ${newCtx}`)
      CTX = newCtx  // persist expansion so subsequent requests use the larger window
      const retry = { ...ollamaBody, options: { ...ollamaBody.options, num_ctx: newCtx } }
      resp = await post(retry)
      if (resp.ok) return resp
      const t3 = await resp.text().catch(() => '')
      throw new Error(`Ollama ${resp.status}: ${t3.slice(0, 300)}`)
    }
  }

  if ('think' in ollamaBody && /think/i.test(txt)) {
    const retry = { ...ollamaBody }
    delete retry.think
    resp = await post(retry)
    if (resp.ok) return resp
    const t2 = await resp.text().catch(() => '')
    throw new Error(`Ollama ${resp.status}: ${t2.slice(0, 300)}`)
  }
  throw new Error(`Ollama ${resp.status}: ${txt.slice(0, 300)}`)
}

function sendError(res, stream, message) {
  log('error:', message)
  if (stream) {
    res.writeHead(200, { 'content-type': 'text/event-stream' })
    sse(res, 'error', { type: 'error', error: { type: 'api_error', message } })
    res.end()
  } else {
    res.writeHead(502, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ type: 'error', error: { type: 'api_error', message } }))
  }
}

function countTokens(reqBody, res) {
  // Rough estimate so `claude`'s pre-flight token counts don't error out.
  let n = 0
  try {
    const body = JSON.parse(reqBody || '{}')
    const s = systemToString(body.system) + JSON.stringify(body.messages || [])
    n = Math.ceil(s.length / 4)
  } catch {}
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ input_tokens: n }))
}

// ---- Server ------------------------------------------------------------------

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && (req.url === '/health' || req.url === '/')) {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ ok: true, ollama: OLLAMA }))
    return
  }
  let body = ''
  req.on('data', c => { body += c })
  req.on('end', () => {
    const url = (req.url || '').split('?')[0]
    if (url.endsWith('/count_tokens')) return countTokens(body, res)
    if (url.startsWith('/v1/messages') || url.endsWith('/messages')) {
      handleMessages(body, res).catch(e => sendError(res, true, e.message))
      return
    }
    res.writeHead(404, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: 'not found', path: url }))
  })
})

server.listen(PORT, '127.0.0.1', () => {
  log(`écoute sur http://127.0.0.1:${PORT}  ->  Ollama ${OLLAMA}`)
})
