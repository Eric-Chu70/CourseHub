import { serve } from "https://deno.land/std@0.181.0/http/server.ts"

interface ContentPart {
  type: string
  text?: string
  image_url?: {
    url: string
  }
}

interface ChatMessage {
  role: string
  content: string | ContentPart[]
}

interface NormalizedMessage {
  role: string
  content: string
}

interface UnifiedChatRequest {
  provider: 'hunyuan' | 'glm' | 'custom'
  messages: ChatMessage[]
  model?: string
  stream?: boolean
  custom_api_url?: string
  custom_api_key?: string
  custom_auth_header?: string
  api_key?: string
  secret_id?: string
  secret_key?: string
  timeout_ms?: number
  reasoning_effort?: 'low' | 'medium' | 'high'
  thinking_disabled?: boolean
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-api-key, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
}

const FIXED_HUNYUAN_MODEL = 'hunyuan-lite'
const FIXED_GLM_MODEL = 'glm-4.7-flash'
const TENCENT_HUNYUAN_DEFAULT_URL = 'https://hunyuan.tencentcloudapi.com/'
const TENCENT_HUNYUAN_DEFAULT_HOST = 'hunyuan.tencentcloudapi.com'
const TENCENT_HUNYUAN_SERVICE = 'hunyuan'
const TENCENT_HUNYUAN_ACTION = 'ChatCompletions'
const TENCENT_HUNYUAN_VERSION = '2023-09-01'

const TEXT_ENCODER = new TextEncoder()

type JsonRecord = Record<string, unknown>

function getEnvVar(key: string): string {
  return Deno.env.get(key) || ''
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  })
}

function errorResponse(message: string, status = 500, extra?: Record<string, unknown>): Response {
  return jsonResponse({ error: message, ...extra }, status)
}

function asRecord(value: unknown): JsonRecord | undefined {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as JsonRecord
  }
  return undefined
}

function readString(record: JsonRecord | undefined, ...keys: string[]): string | undefined {
  if (!record) return undefined
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'string' && value.length > 0) {
      return value
    }
  }
  return undefined
}

function readStringLike(record: JsonRecord | undefined, ...keys: string[]): string | undefined {
  if (!record) return undefined
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'string' && value.length > 0) {
      return value
    }
    if (Array.isArray(value)) {
      const parts: string[] = []
      for (const item of value) {
        if (typeof item === 'string') {
          parts.push(item)
          continue
        }
        const itemRecord = asRecord(item)
        if (!itemRecord) continue
        const itemText = pickString(
          readString(itemRecord, 'text', 'Text'),
          readString(itemRecord, 'content', 'Content'),
          readString(itemRecord, 'value', 'Value'),
          readString(itemRecord, 'reasoning_content', 'ReasoningContent', 'reasoningContent'),
          readString(itemRecord, 'reasoning', 'Reasoning'),
        )
        if (itemText) {
          parts.push(itemText)
        }
      }
      const joined = parts.join('')
      if (joined.length > 0) {
        return joined
      }
    }
  }
  return undefined
}

function getRootPayload(parsed: JsonRecord): JsonRecord {
  const responsePayload = asRecord(parsed.Response)
  return responsePayload || parsed
}

function getChoices(root: JsonRecord): JsonRecord[] | undefined {
  const choices = root.choices ?? root.Choices
  if (!Array.isArray(choices)) return undefined
  return choices.filter((item) => item && typeof item === 'object') as JsonRecord[]
}

function firstTextContent(content: string | ContentPart[]): string {
  if (typeof content === 'string') return content
  const textPart = content.find((part) => part.type === 'text' && part.text)
  return textPart?.text || ''
}

function normalizeMessages(messages: ChatMessage[]): NormalizedMessage[] {
  return messages
    .map((msg) => ({ role: msg.role, content: firstTextContent(msg.content) }))
    .filter((msg) => msg.content.length > 0)
}

function normalizeMessagesForProvider(
  provider: UnifiedChatRequest['provider'],
  messages: ChatMessage[],
): Array<Record<string, unknown>> {
  if (provider === 'custom') {
    return messages
      .map((msg) => ({
        role: msg.role,
        content: msg.content,
      }))
      .filter((msg) => {
        const content = msg.content
        if (typeof content === 'string') return content.length > 0
        if (Array.isArray(content)) return content.length > 0
        return false
      })
  }

  return normalizeMessages(messages).map((msg) => ({
    role: msg.role,
    content: msg.content,
  }))
}

function pickString(...values: Array<string | null | undefined>): string | undefined {
  for (const value of values) {
    if (typeof value === 'string' && value.length > 0) {
      return value
    }
  }
  return undefined
}

function extractContent(parsed: Record<string, unknown>): string | undefined {
  const parsedRoot = parsed as JsonRecord
  const root = getRootPayload(parsed as JsonRecord)
  const choices = getChoices(root)
  const delta = asRecord(choices?.[0]?.delta) || asRecord(choices?.[0]?.Delta)
  const message = asRecord(choices?.[0]?.message) || asRecord(choices?.[0]?.Message)
  const output = asRecord(root.output) || asRecord(root.Output)

  const eventType = readString(parsedRoot, 'type', 'Type')
  if (eventType === 'response.output_text.delta') {
    const deltaText = readStringLike(parsedRoot, 'delta', 'Delta')
    if (deltaText) return deltaText
  }
  if (eventType === 'response.output_text.done' || eventType === 'response.output_item.done') {
    const doneText = readStringLike(parsedRoot, 'text', 'Text', 'delta', 'Delta', 'output_text', 'outputText')
    if (doneText) return doneText
  }

  return pickString(
    readStringLike(parsedRoot, 'content', 'Content', 'output_text', 'outputText'),
    readString(root, 'content', 'Content'),
    readStringLike(root, 'content', 'Content'),
    readString(delta, 'content', 'Content'),
    readStringLike(delta, 'content', 'Content'),
    readString(delta, 'text', 'Text'),
    readStringLike(delta, 'text', 'Text'),
    readString(message, 'content', 'Content'),
    readStringLike(message, 'content', 'Content'),
    readString(output, 'text', 'Text'),
    readStringLike(output, 'text', 'Text'),
  )
}

function extractStatus(parsed: Record<string, unknown>): string | undefined {
  const parsedRoot = parsed as JsonRecord
  const root = getRootPayload(parsed as JsonRecord)

  const eventType = readString(parsedRoot, 'type', 'Type')
  if (eventType === 'response.web_search_call.in_progress') {
    return '正在搜索网络...'
  }
  if (eventType === 'response.web_search_call.completed') {
    return '搜索完成，正在整理答案...'
  }

  return readString(root, 'status', 'Status')
}

function extractThinking(parsed: Record<string, unknown>): string | undefined {
  const parsedRoot = parsed as JsonRecord
  const root = getRootPayload(parsed as JsonRecord)
  const direct = readString(root, 'thinking', 'Thinking')
  if (direct) return direct

  const eventType = readString(parsedRoot, 'type', 'Type')
  if (eventType === 'response.reasoning_summary_text.delta' || eventType === 'response.reasoning.delta') {
    const eventThinking = readStringLike(parsedRoot, 'delta', 'Delta')
    if (eventThinking) return eventThinking
  }

  const choices = getChoices(root)
  const delta = asRecord(choices?.[0]?.delta) || asRecord(choices?.[0]?.Delta)
  const message = asRecord(choices?.[0]?.message) || asRecord(choices?.[0]?.Message)
  return pickString(
    readStringLike(parsedRoot, 'reasoning_content', 'reasoningContent', 'ReasoningContent', 'reasoning', 'Reasoning', 'thinking', 'Thinking'),
    readString(delta, 'reasoning_content'),
    readString(delta, 'reasoningContent'),
    readString(delta, 'ReasoningContent'),
    readString(delta, 'reasoning'),
    readString(delta, 'Reasoning'),
    readStringLike(delta, 'reasoning_content', 'reasoningContent', 'ReasoningContent', 'reasoning', 'Reasoning', 'thinking', 'Thinking'),
    readString(message, 'reasoning_content'),
    readString(message, 'reasoningContent'),
    readStringLike(message, 'reasoning_content', 'reasoningContent', 'ReasoningContent', 'reasoning', 'Reasoning', 'thinking', 'Thinking'),
    readStringLike(root, 'reasoning_content', 'reasoningContent', 'ReasoningContent', 'reasoning', 'Reasoning', 'thinking', 'Thinking'),
    readString(root, 'reasoning_content', 'reasoningContent', 'ReasoningContent'),
  )
}

function extractModel(parsed: Record<string, unknown>, fallback: string): string {
  const root = getRootPayload(parsed as JsonRecord)
  const parsedModel = pickString(readString(root, 'model'), readString(root, 'Model'))
  return parsedModel || fallback
}

function extractErrorMessage(parsed: Record<string, unknown>): string | undefined {
  const root = getRootPayload(parsed as JsonRecord)

  const openAiError = asRecord((parsed as JsonRecord).error) || asRecord(root.error)
  if (openAiError) {
    return pickString(
      readString(openAiError, 'message', 'Message'),
      JSON.stringify(openAiError),
    )
  }

  const tencentError = asRecord((parsed as JsonRecord).Error) || asRecord(root.Error)
  if (tencentError) {
    const code = readString(tencentError, 'Code', 'code')
    const message = readString(tencentError, 'Message', 'message')
    return code && message ? `${code}: ${message}` : (message || code)
  }

  const directError = (parsed as JsonRecord).error
  if (typeof directError === 'string' && directError.length > 0) {
    return directError
  }

  return undefined
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

async function sha256Hex(value: string): Promise<string> {
  const hashBuffer = await crypto.subtle.digest('SHA-256', TEXT_ENCODER.encode(value))
  return bytesToHex(new Uint8Array(hashBuffer))
}

async function hmacSha256(key: Uint8Array | string, value: string): Promise<Uint8Array> {
  const rawKey = typeof key === 'string' ? TEXT_ENCODER.encode(key) : key
  const normalizedKey = new Uint8Array(rawKey)
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    normalizedKey as unknown as BufferSource,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign('HMAC', cryptoKey, TEXT_ENCODER.encode(value))
  return new Uint8Array(signature)
}

function getUtcDate(timestamp: number): string {
  return new Date(timestamp * 1000).toISOString().slice(0, 10)
}

function normalizeTencentMessages(messages: ChatMessage[]): Array<Record<string, string>> {
  return normalizeMessages(messages).map((msg) => ({
    Role: msg.role,
    Content: msg.content,
  }))
}

async function buildTencentHunyuanHeaders(options: {
  secretId: string
  secretKey: string
  host: string
  payload: string
  region?: string
  stream: boolean
}): Promise<Record<string, string>> {
  const {
    secretId,
    secretKey,
    host,
    payload,
    region,
    stream,
  } = options

  const algorithm = 'TC3-HMAC-SHA256'
  const timestamp = Math.floor(Date.now() / 1000)
  const date = getUtcDate(timestamp)

  const canonicalHeaders = `content-type:application/json; charset=utf-8\nhost:${host}\nx-tc-action:${TENCENT_HUNYUAN_ACTION.toLowerCase()}\n`
  const signedHeaders = 'content-type;host;x-tc-action'
  const hashedPayload = await sha256Hex(payload)
  const canonicalRequest = `POST\n/\n\n${canonicalHeaders}\n${signedHeaders}\n${hashedPayload}`

  const credentialScope = `${date}/${TENCENT_HUNYUAN_SERVICE}/tc3_request`
  const hashedCanonicalRequest = await sha256Hex(canonicalRequest)
  const stringToSign = `${algorithm}\n${timestamp}\n${credentialScope}\n${hashedCanonicalRequest}`

  const secretDate = await hmacSha256(`TC3${secretKey}`, date)
  const secretService = await hmacSha256(secretDate, TENCENT_HUNYUAN_SERVICE)
  const secretSigning = await hmacSha256(secretService, 'tc3_request')
  const signature = bytesToHex(await hmacSha256(secretSigning, stringToSign))

  const authorization = `${algorithm} Credential=${secretId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`

  const headers: Record<string, string> = {
    Authorization: authorization,
    'Content-Type': 'application/json; charset=utf-8',
    Host: host,
    'X-TC-Action': TENCENT_HUNYUAN_ACTION,
    'X-TC-Timestamp': String(timestamp),
    'X-TC-Version': TENCENT_HUNYUAN_VERSION,
  }

  if (region && region.length > 0) {
    headers['X-TC-Region'] = region
  }
  if (stream) {
    headers.Accept = 'text/event-stream'
  }

  return headers
}

async function proxyStreamResponse(
  upstream: Response,
  fallbackModel: string,
): Promise<Response> {
  const reader = upstream.body?.getReader()
  if (!reader) {
    return errorResponse('No response body', 500)
  }

  const encoder = new TextEncoder()
  const decoder = new TextDecoder()

  const stream = new ReadableStream({
    async start(controller) {
      let buffer = ''
      let sawDoneToken = false
      let sawContentChunk = false

      const processLine = (line: string) => {
        const trimmed = line.trim()
        if (!trimmed || !trimmed.startsWith('data:')) return

        const data = trimmed.slice(5).trim()
        if (data === '[DONE]') {
          sawDoneToken = true
          if (!sawContentChunk) {
            controller.enqueue(
              encoder.encode(
                `data: ${JSON.stringify({ error: 'Upstream stream ended with [DONE] but produced no content' })}\n\n`,
              ),
            )
            return
          }
          controller.enqueue(encoder.encode('data: [DONE]\n\n'))
          return
        }

        try {
          const parsed = JSON.parse(data) as Record<string, unknown>
          const model = extractModel(parsed, fallbackModel)
          const error = extractErrorMessage(parsed)
          const thinking = extractThinking(parsed)
          const status = extractStatus(parsed)
          const content = extractContent(parsed)

          if (error) {
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error, model })}\n\n`))
            return
          }

          if (thinking) {
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({ thinking, model })}\n\n`))
          }
          if (status) {
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({ status, model })}\n\n`))
          }
          if (content) {
            sawContentChunk = true
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({ content, model })}\n\n`))
          }
        } catch {
          // Ignore malformed payload and continue streaming.
        }
      }

      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split('\n')
          buffer = lines.pop() || ''

          for (const line of lines) {
            processLine(line)
          }
        }

        // Process any trailing line that may not end with a newline.
        if (buffer.trim().length > 0) {
          processLine(buffer)
        }

        if (!sawDoneToken) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error: 'Upstream stream ended unexpectedly before [DONE]' })}\n\n`))
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error: message })}\n\n`))
      } finally {
        controller.close()
      }
    },
  })

  return new Response(stream, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    },
  })
}

async function normalizeNonStreamResponse(upstream: Response, fallbackModel: string): Promise<Response> {
  const data = await upstream.json() as Record<string, unknown>

  const error = extractErrorMessage(data)
  if (error) {
    return errorResponse(error, 500)
  }

  const content = extractContent(data)
  if (!content) {
    return errorResponse('No response content from upstream', 500)
  }

  const model = extractModel(data, fallbackModel)

  return jsonResponse({
    choices: [
      {
        message: {
          role: 'assistant',
          content,
        },
      },
    ],
    model,
  })
}

async function callUpstream(
  url: string,
  headers: Record<string, string>,
  body: string,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(url, {
      method: 'POST',
      headers,
      body,
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timer)
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS })
  }

  if (req.method !== 'POST') {
    return errorResponse('Method not allowed', 405)
  }

  try {
    const body = await req.json() as UnifiedChatRequest
    const {
      provider,
      messages,
      model,
      stream = false,
      custom_api_url,
      custom_api_key,
      custom_auth_header,
      api_key,
      secret_id,
      secret_key,
      timeout_ms,
      reasoning_effort,
      thinking_disabled,
    } = body

    if (!provider || !['hunyuan', 'glm', 'custom'].includes(provider)) {
      return errorResponse('provider must be one of: hunyuan, glm, custom', 400)
    }

    if (!messages?.length) {
      return errorResponse('Missing messages in request body', 400)
    }

    // Custom providers may have high first-token latency; keep timeout configurable and more tolerant by default.
    const timeout = Math.max(15000, Math.min(timeout_ms ?? 300000, 900000))

    let upstreamUrl = ''
    let upstreamHeaders: Record<string, string> = { 'Content-Type': 'application/json' }
    let upstreamBody: Record<string, unknown>
    let upstreamBodyText = ''
    let fallbackModel = model || provider

    if (provider === 'hunyuan') {
      upstreamUrl = pickString(
        getEnvVar('HUNYUAN_BASE_URL'),
        TENCENT_HUNYUAN_DEFAULT_URL,
      ) || ''
      const hunyuanSecretId = pickString(
        getEnvVar('HUNYUAN_SECRET_ID'),
        secret_id,
      )
      const hunyuanSecretKey = pickString(
        getEnvVar('HUNYUAN_SECRET_KEY'),
        secret_key,
      )
      if (!hunyuanSecretId || !hunyuanSecretKey) {
        return errorResponse('HUNYUAN SecretId/SecretKey not configured', 500)
      }

      let host = TENCENT_HUNYUAN_DEFAULT_HOST
      try {
        host = new URL(upstreamUrl).host || host
      } catch {
        host = TENCENT_HUNYUAN_DEFAULT_HOST
      }

      fallbackModel = FIXED_HUNYUAN_MODEL
      upstreamBody = {
        Model: FIXED_HUNYUAN_MODEL,
        Messages: normalizeTencentMessages(messages),
        Stream: stream,
      }
      upstreamBodyText = JSON.stringify(upstreamBody)

      upstreamHeaders = await buildTencentHunyuanHeaders({
        secretId: hunyuanSecretId,
        secretKey: hunyuanSecretKey,
        host,
        payload: upstreamBodyText,
        region: pickString(getEnvVar('HUNYUAN_REGION')),
        stream,
      })
    } else if (provider === 'glm') {
      upstreamUrl = pickString(getEnvVar('GLM_BASE_URL'), 'https://open.bigmodel.cn/api/paas/v4/chat/completions') || ''
      const glmApiKey = pickString(getEnvVar('GLM_API_KEY'), api_key)
      if (!glmApiKey) {
        return errorResponse('GLM API key not configured', 500)
      }

      upstreamHeaders.Authorization = `Bearer ${glmApiKey}`
      fallbackModel = FIXED_GLM_MODEL
      upstreamBody = {
        model: FIXED_GLM_MODEL,
        messages: normalizeMessages(messages),
        stream,
        max_tokens: 2048,
      }
      upstreamBodyText = JSON.stringify(upstreamBody)
    } else {
      upstreamUrl = pickString(custom_api_url, getEnvVar('CUSTOM_API_URL')) || ''
      const customApiKey = pickString(custom_api_key, getEnvVar('CUSTOM_API_KEY'))

      if (!upstreamUrl || !customApiKey) {
        return errorResponse('custom provider requires custom_api_url and custom_api_key', 400)
      }

      const authHeader = (custom_auth_header || '').trim().toLowerCase()
      if (authHeader === 'api-key') {
        upstreamHeaders['api-key'] = customApiKey
      } else {
        upstreamHeaders.Authorization = `Bearer ${customApiKey}`
      }
      if (stream) {
        upstreamHeaders.Accept = 'text/event-stream'
      }

      fallbackModel = model || getEnvVar('CUSTOM_API_MODEL') || 'gpt-4o-mini'
      upstreamBody = {
        model: fallbackModel,
        messages: normalizeMessagesForProvider('custom', messages),
        stream,
      }
      const validEfforts = new Set(['low', 'medium', 'high'])
      if (reasoning_effort && reasoning_effort.length > 0 && validEfforts.has(reasoning_effort)) {
        upstreamBody.reasoning_effort = reasoning_effort
      }
      if (thinking_disabled) {
        upstreamBody.thinking = { type: 'disabled' }
      }
      upstreamBodyText = JSON.stringify(upstreamBody)
    }

    const upstream = await callUpstream(upstreamUrl, upstreamHeaders, upstreamBodyText, timeout)

    if (!upstream.ok) {
      const errorText = await upstream.text()
      return errorResponse(`HTTP ${upstream.status}: ${errorText}`, upstream.status)
    }

    if (stream) {
      return proxyStreamResponse(upstream, fallbackModel)
    }

    return normalizeNonStreamResponse(upstream, fallbackModel)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return errorResponse(message, 500)
  }
})
