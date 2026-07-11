import { serve } from "https://deno.land/std@0.181.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3'

interface ChatMessage {
  role: string
  content: string | ContentPart[]
}

interface ContentPart {
  type: string
  text?: string
  image_url?: {
    url: string
  }
}

interface ChatRequest {
  messages: ChatMessage[]
  model?: string
  type?: 'vision' | 'chat'
  stream?: boolean
  fast_mode?: boolean
  enable_search?: boolean
}

interface DoubaoResponse {
  choices?: Array<{
    message: {
      role: string
      content: string
    }
    delta?: {
      content: string
    }
    finish_reason: string
  }>
  usage?: {
    prompt_tokens: number
    completion_tokens: number
    total_tokens: number
    tool_usage?: number
    tool_usage_details?: Record<string, number>
  }
  error?: {
    message: string
    type: string
  }
  output?: {
    text: string
    finish_reason: string
  }
}

interface TokenUsageRecord {
  id: string
  model_name: string
  usage_date: string
  total_tokens: number
  request_count: number
}

interface SearchUsageRecord {
  id: string
  usage_month: string
  search_count: number
}

interface EndpointSelection {
  endpoint: string
  modelName: string
  switchedFrom?: string
}

const DAILY_TOKEN_LIMIT = 2000000
const MONTHLY_SEARCH_LIMIT = 20000
const API_BASE_URL = 'https://ark.cn-beijing.volces.com/api/v3/chat/completions'
const RESPONSES_API_URL = 'https://ark.cn-beijing.volces.com/api/v3/responses'
const BOT_API_URL = 'https://ark.cn-beijing.volces.com/api/v3/bots/chat/completions'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-api-key, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
}

function getEnvVar(key: string): string {
  return Deno.env.get(key) || ''
}

function buildEndpoints(prefix: string, count: number, startFrom: number = 1): string[] {
  const endpoints: string[] = []
  for (let i = startFrom; i < startFrom + count; i++) {
    const endpoint = getEnvVar(`${prefix}_${i}`)
    if (endpoint) endpoints.push(endpoint)
  }
  return endpoints
}

const VISION_ENDPOINTS = buildEndpoints('VISION_ENDPOINT', 3, 1)
const CHAT_ENDPOINTS = buildEndpoints('CHAT_ENDPOINT', 3, 1)
const FAST_ENDPOINTS = buildEndpoints('FAST_ENDPOINT', 3, 4)
const FIXED_VISION_ENDPOINT = getEnvVar('FIXED_VISION_ENDPOINT') || getEnvVar('VISION_ENDPOINT_FIXED')
const FIXED_VISION_MODEL = getEnvVar('FIXED_VISION_MODEL')

const API_KEY = getEnvVar('DOUBAO_API_KEY')
const SUPABASE_URL = getEnvVar('SUPABASE_URL')
const SUPABASE_SERVICE_ROLE_KEY = getEnvVar('SUPABASE_SERVICE_ROLE_KEY')

const supabase = SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY 
  ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  : null

const MODEL_MAPPINGS: Array<{ envKey: string; modelName: string; apiType?: 'chat' | 'responses' | 'bot' }> = [
  { envKey: 'CHAT_ENDPOINT_1', modelName: 'GLM-4.7', apiType: 'responses' },
  { envKey: 'CHAT_ENDPOINT_2', modelName: 'Doubao-Seed-2.0-mini', apiType: 'responses' },
  { envKey: 'CHAT_ENDPOINT_3', modelName: 'Doubao-Seed-2.0-pro', apiType: 'responses' },
  { envKey: 'VISION_ENDPOINT_1', modelName: 'Doubao-Vision-Pro' },
  { envKey: 'VISION_ENDPOINT_2', modelName: 'Doubao-Vision-Pro-2' },
  { envKey: 'VISION_ENDPOINT_3', modelName: 'Doubao-Vision-Pro-3' },
  { envKey: 'FAST_ENDPOINT_4', modelName: 'DeepSeek-V3.2', apiType: 'responses' },
  { envKey: 'FAST_ENDPOINT_5', modelName: 'DeepSeek-R1', apiType: 'bot' },
  { envKey: 'FAST_ENDPOINT_6', modelName: 'DeepSeek-V3.1', apiType: 'responses' },
]

const ENDPOINT_TO_MODEL: Record<string, string> = {}
const MODEL_TO_ENDPOINT: Record<string, string> = {}
const MODEL_TO_API_TYPE: Record<string, 'chat' | 'responses' | 'bot'> = {}

for (const { envKey, modelName, apiType } of MODEL_MAPPINGS) {
  const endpoint = getEnvVar(envKey)
  if (endpoint) {
    ENDPOINT_TO_MODEL[endpoint] = modelName
    MODEL_TO_ENDPOINT[modelName] = endpoint
    if (apiType) {
      MODEL_TO_API_TYPE[modelName] = apiType
    }
  }
}

function getModelName(endpoint: string): string {
  return ENDPOINT_TO_MODEL[endpoint] || endpoint
}

function getEndpointByModelName(modelName: string): string | null {
  return MODEL_TO_ENDPOINT[modelName] || null
}

function getApiTypeByModelName(modelName: string): 'chat' | 'responses' | 'bot' {
  return MODEL_TO_API_TYPE[modelName] || 'chat'
}

function estimateTokens(messages: ChatMessage[]): number {
  let totalChars = 0
  for (const msg of messages) {
    if (typeof msg.content === 'string') {
      totalChars += msg.content.length
    } else if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        if (part.text) totalChars += part.text.length
      }
    }
    totalChars += msg.role.length
  }
  return Math.ceil(totalChars / 4)
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS }
  })
}

function errorResponse(message: string, status = 500, extra?: Record<string, unknown>): Response{
  return jsonResponse({ error: message, ...extra }, status)
}

function getCurrentMonth(): string {
  const now = new Date()
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`
}

const tokenUsageCache = new Map<string, number>()
const searchUsageCache = new Map<string, number>()

async function getTodayTokenUsage(modelName: string): Promise<number>{
  if (!supabase) return 0
  
  const cacheKey = `${modelName}:${new Date().toISOString().split('T')[0]}`
  if (tokenUsageCache.has(cacheKey)) {
    return tokenUsageCache.get(cacheKey)!
  }
  
  const today = new Date().toISOString().split('T')[0]
  
  const { data, error } = await supabase
    .from('token_usage')
    .select('total_tokens')
    .eq('model_name', modelName)
    .eq('usage_date', today)
    .maybeSingle()
  
  const usage = error || !data ? 0 : (data as TokenUsageRecord).total_tokens
  tokenUsageCache.set(cacheKey, usage)
  return usage
}

async function getMonthlySearchUsage(): Promise<number>{
  if (!supabase) return 0
  
  const currentMonth = getCurrentMonth()
  
  if (searchUsageCache.has(currentMonth)) {
    return searchUsageCache.get(currentMonth)!
  }
  
  const { data, error } = await supabase
    .from('search_usage')
    .select('search_count')
    .eq('usage_month', currentMonth)
    .maybeSingle()
  
  const usage = error || !data ? 0 : (data as SearchUsageRecord).search_count
  searchUsageCache.set(currentMonth, usage)
  return usage
}

async function recordTokenUsage(modelName: string, tokens: number): Promise<void>{
  if (!supabase || tokens <= 0) return
  
  const today = new Date().toISOString().split('T')[0]
  const cacheKey = `${modelName}:${today}`
  tokenUsageCache.delete(cacheKey)
  
  const { data: existing } = await supabase
    .from('token_usage')
    .select('*')
    .eq('model_name', modelName)
    .eq('usage_date', today)
    .maybeSingle()
  
  if (existing) {
    const record = existing as TokenUsageRecord
    await supabase
      .from('token_usage')
      .update({
        total_tokens: record.total_tokens + tokens,
        request_count: record.request_count + 1
      })
      .eq('id', record.id)
  } else {
    await supabase
      .from('token_usage')
      .insert({
        model_name: modelName,
        usage_date: today,
        total_tokens: tokens,
        request_count: 1
      })
  }
}

async function recordSearchUsage(count: number): Promise<void>{
  if (!supabase || count <= 0) return
  
  const currentMonth = getCurrentMonth()
  searchUsageCache.delete(currentMonth)
  
  const { data: existing } = await supabase
    .from('search_usage')
    .select('*')
    .eq('usage_month', currentMonth)
    .maybeSingle()
  
  if (existing) {
    const record = existing as SearchUsageRecord
    await supabase
      .from('search_usage')
      .update({
        search_count: record.search_count + count
      })
      .eq('id', record.id)
  } else {
    await supabase
      .from('search_usage')
      .insert({
        usage_month: currentMonth,
        search_count: count
      })
  }
}

async function findAvailableEndpoint(
  endpoints: string[],
  estimatedTokens: number
): Promise<EndpointSelection | null>{
  const shuffled = [...endpoints].sort(() => Math.random() - 0.5)
  
  for (const endpoint of shuffled) {
    const modelName = getModelName(endpoint)
    const currentUsage = await getTodayTokenUsage(modelName)
    
    if (currentUsage + estimatedTokens <= DAILY_TOKEN_LIMIT) {
      return { endpoint, modelName }
    }
  }
  return null
}

async function findAvailableEndpointInOrder(
  endpoints: string[],
  estimatedTokens: number
): Promise<EndpointSelection | null> {
  for (const endpoint of endpoints) {
    const modelName = getModelName(endpoint)
    const currentUsage = await getTodayTokenUsage(modelName)

    if (currentUsage + estimatedTokens <= DAILY_TOKEN_LIMIT) {
      return { endpoint, modelName }
    }
  }
  return null
}

function getVisionEndpointsByPriority(): string[] {
  const endpoints = [...VISION_ENDPOINTS]

  if (FIXED_VISION_ENDPOINT && endpoints.includes(FIXED_VISION_ENDPOINT)) {
    return [FIXED_VISION_ENDPOINT, ...endpoints.filter((e) => e !== FIXED_VISION_ENDPOINT)]
  }

  if (FIXED_VISION_MODEL) {
    const endpointFromModel = getEndpointByModelName(FIXED_VISION_MODEL)
    if (endpointFromModel && endpoints.includes(endpointFromModel)) {
      return [endpointFromModel, ...endpoints.filter((e) => e !== endpointFromModel)]
    }
  }

  return endpoints
}

async function selectVisionEndpoint(
  availableEndpoints: string[],
  requestedModel: string | undefined,
  estimatedTokens: number,
): Promise<EndpointSelection | null> {
  if (requestedModel) {
    const endpointFromModel = getEndpointByModelName(requestedModel)
    if (endpointFromModel && availableEndpoints.includes(endpointFromModel)) {
      const modelName = getModelName(endpointFromModel)
      const currentUsage = await getTodayTokenUsage(modelName)

      if (currentUsage + estimatedTokens <= DAILY_TOKEN_LIMIT) {
        return { endpoint: endpointFromModel, modelName }
      }

      const result = await findAvailableEndpointInOrder(availableEndpoints, estimatedTokens)
      if (result) {
        return { ...result, switchedFrom: modelName }
      }
      return null
    }
  }

  return findAvailableEndpointInOrder(availableEndpoints, estimatedTokens)
}

async function selectEndpoint(
  availableEndpoints: string[],
  requestedModel: string | undefined,
  estimatedTokens: number
): Promise<EndpointSelection | null>{
  if (requestedModel) {
    const endpointFromModel = getEndpointByModelName(requestedModel)
    if (endpointFromModel && availableEndpoints.includes(endpointFromModel)) {
      const modelName = getModelName(endpointFromModel)
      const currentUsage = await getTodayTokenUsage(modelName)
      
      if (currentUsage + estimatedTokens <= DAILY_TOKEN_LIMIT) {
        return { endpoint: endpointFromModel, modelName }
      }
      
      const result = await findAvailableEndpoint(availableEndpoints, estimatedTokens)
      if (result) {
        return { ...result, switchedFrom: modelName }
      }
      return null
    }
  }
  
  return findAvailableEndpoint(availableEndpoints, estimatedTokens)
}

async function handleStreamResponse(
  response: Response,
  selectedEndpoint: string,
  estimatedInputTokens: number,
  switchedFrom?: string,
  enableSearch?: boolean
): Promise<Response>{
  const reader = response.body?.getReader()
  if (!reader) {
    return errorResponse('No response body', 500)
  }

  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const modelName = getModelName(selectedEndpoint)
  let outputText = ''
  let totalToolUsage = 0

  const stream = new ReadableStream({
    async start(controller) {
      let buffer = ''
      
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split('\n')
          buffer = lines.pop() || ''

          for (const line of lines) {
            const trimmed = line.trim()
            if (!trimmed || !trimmed.startsWith('data:')) continue
            
            const data = trimmed.slice(5).trim()
            if (data === '[DONE]') {
              controller.enqueue(encoder.encode(`data: [DONE]\n\n`))
              continue
            }

            try {
              const parsed = JSON.parse(data)
              const delta = parsed.choices?.[0]?.delta
              
              if (delta?.content) {
                outputText += delta.content
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ content: delta.content, model: modelName, switched_from: switchedFrom })}\n\n`))
              }
              
              if (parsed.usage?.tool_usage) {
                totalToolUsage = parsed.usage.tool_usage
              }
            } catch {
              // Skip invalid JSON
            }
          }
        }
        
        controller.enqueue(encoder.encode(`data: [DONE]\n\n`))
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error: message })}\n\n`))
      } finally {
        const totalOutputTokens = Math.ceil(outputText.length / 4)
        await recordTokenUsage(modelName, estimatedInputTokens + totalOutputTokens)
        if (totalToolUsage > 0 && enableSearch) {
          await recordSearchUsage(totalToolUsage)
        }
        controller.close()
      }
    }
  })

  return new Response(stream, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    }
  })
}

async function handleBotStream(
  response: Response,
  botId: string,
  estimatedInputTokens: number,
  switchedFrom?: string
): Promise<Response>{
  const reader = response.body?.getReader()
  if (!reader) {
    return errorResponse('No response body', 500)
  }

  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const modelName = 'DeepSeek-R1'
  let outputText = ''

  const stream = new ReadableStream({
    async start(controller) {
      let buffer = ''
      
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split('\n')
          buffer = lines.pop() || ''

          for (const line of lines) {
            const trimmed = line.trim()
            if (!trimmed || !trimmed.startsWith('data:')) continue
            
            const data = trimmed.slice(5).trim()
            if (data === '[DONE]') {
              controller.enqueue(encoder.encode(`data: [DONE]\n\n`))
              continue
            }

            try {
              const parsed = JSON.parse(data)
              const delta = parsed.choices?.[0]?.delta
              
              if (delta?.reasoning_content) {
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ thinking: delta.reasoning_content, model: modelName })}\n\n`))
              }
              
              if (delta?.content) {
                outputText += delta.content
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ content: delta.content, model: modelName, switched_from: switchedFrom })}\n\n`))
              }
            } catch {
              // Skip invalid JSON
            }
          }
        }
        
        controller.enqueue(encoder.encode(`data: [DONE]\n\n`))
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error: message })}\n\n`))
      } finally {
        const totalOutputTokens = Math.ceil(outputText.length / 4)
        await recordTokenUsage(modelName, estimatedInputTokens + totalOutputTokens)
        controller.close()
      }
    }
  })

  return new Response(stream, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    }
  })
}

async function handleResponsesStream(
  response: Response,
  selectedEndpoint: string,
  estimatedInputTokens: number,
  switchedFrom?: string
): Promise<Response>{
  const reader = response.body?.getReader()
  if (!reader) {
    return errorResponse('No response body', 500)
  }

  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const modelName = getModelName(selectedEndpoint)
  let outputText = ''
  let totalToolUsage = 0

  const stream = new ReadableStream({
    async start(controller) {
      let buffer = ''
      
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split('\n')
          buffer = lines.pop() || ''

          for (const line of lines) {
            const trimmed = line.trim()
            if (!trimmed || !trimmed.startsWith('data:')) continue
            
            const data = trimmed.slice(5).trim()
            if (data === '[DONE]') {
              controller.enqueue(encoder.encode(`data: [DONE]\n\n`))
              continue
            }

            try {
              const parsed = JSON.parse(data)
              const eventType = parsed.type || ''
              
              console.log('Event type:', eventType, 'Data:', JSON.stringify(parsed).substring(0, 200))
              
              // 处理输出文本增量
              if (eventType === 'response.output_text.delta') {
                const delta = parsed.delta || ''
                outputText += delta
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ content: delta, model: modelName, switched_from: switchedFrom })}\n\n`))
              }
              // 处理推理/思考过程增量 - 不发送给前端
              else if (eventType === 'response.reasoning_summary_text.delta') {
                console.log('Reasoning:', parsed.delta || '')
              }
              // 处理搜索调用
              else if (eventType === 'response.web_search_call.in_progress') {
                console.log('Web search started')
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ status: '正在搜索网络...', model: modelName })}\n\n`))
              }
              else if (eventType === 'response.web_search_call.completed') {
                console.log('Web search completed')
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ status: '搜索完成，正在整理答案...', model: modelName })}\n\n`))
              }
              // 处理最终完成事件
              else if (eventType === 'response.completed') {
                console.log('Response completed, full data:', JSON.stringify(parsed).substring(0, 500))
                if (parsed.response?.usage) {
                  const usage = parsed.response.usage
                  console.log('Usage:', JSON.stringify(usage))
                  if (usage.tool_usage?.web_search) {
                    totalToolUsage = usage.tool_usage.web_search
                    console.log('Total web search calls:', totalToolUsage)
                  }
                }
              }
              // 处理输出项完成事件
              else if (eventType === 'response.output_item.done') {
                console.log('Output item done:', JSON.stringify(parsed).substring(0, 300))
              }
            } catch (e) {
              console.log('JSON parse error:', e, 'Data:', data.substring(0, 100))
            }
          }
        }
        
        controller.enqueue(encoder.encode(`data: [DONE]\n\n`))
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error: message })}\n\n`))
      } finally {
        const totalOutputTokens = Math.ceil(outputText.length / 4)
        await recordTokenUsage(modelName, estimatedInputTokens + totalOutputTokens)
        if (totalToolUsage > 0) {
          await recordSearchUsage(totalToolUsage)
        }
        controller.close()
      }
    }
  })

  return new Response(stream, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    }
  })
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS })
  }

  if (!API_KEY) {
    return errorResponse('API key not configured on server', 500)
  }

  try {
    const body = await req.json() as ChatRequest
    const { messages, model, type = 'vision', stream = false, fast_mode = false, enable_search = false } = body

    console.log('=== Request Debug ===')
    console.log('Received fast_mode:', fast_mode, typeof fast_mode)
    console.log('Received type:', type)
    console.log('Received model:', model)
    console.log('Enable search:', enable_search)
    console.log('FAST_ENDPOINTS length:', FAST_ENDPOINTS.length)
    console.log('CHAT_ENDPOINTS length:', CHAT_ENDPOINTS.length)
    console.log('=====================')

    if (!messages?.length) {
      return errorResponse('Missing messages in request body', 400)
    }

    if (enable_search && type === 'vision') {
      return errorResponse('视觉模型不支持联网搜索功能', 400)
    }

    if (enable_search) {
      const currentSearchUsage = await getMonthlySearchUsage()
      console.log('Current month search usage:', currentSearchUsage, '/', MONTHLY_SEARCH_LIMIT)
      
      if (currentSearchUsage >= MONTHLY_SEARCH_LIMIT) {
        return errorResponse('本月联网搜索次数已达上限', 429, { 
          monthly_usage: currentSearchUsage, 
          monthly_limit: MONTHLY_SEARCH_LIMIT 
        })
      }
    }

    let availableEndpoints: string[]
    if (type === 'vision') {
      availableEndpoints = getVisionEndpointsByPriority()
      console.log('Using VISION mode - fixed-first endpoints:', availableEndpoints)
      if (FIXED_VISION_MODEL) {
        console.log('Fixed vision model configured:', FIXED_VISION_MODEL)
      }
    } else if (fast_mode) {
      console.log('Using FAST mode - selecting from FAST_ENDPOINTS only')
      if (FAST_ENDPOINTS.length === 0) {
        return errorResponse('快速响应模式暂未配置，请在设置中关闭快速响应模式', 503)
      }
      availableEndpoints = FAST_ENDPOINTS
    } else {
      console.log('Using NORMAL mode - selecting from all endpoints')
      availableEndpoints = [...CHAT_ENDPOINTS, ...FAST_ENDPOINTS]
    }
    
    if (availableEndpoints.length === 0) {
      return errorResponse('No endpoints configured. Please set environment variables.', 500)
    }

    const estimatedInputTokens = estimateTokens(messages)

    let selection: EndpointSelection | null
    if (type === 'vision') {
      const preferredVisionModel = model || FIXED_VISION_MODEL || getModelName(availableEndpoints[0])
      selection = await selectVisionEndpoint(availableEndpoints, preferredVisionModel, estimatedInputTokens)
    } else {
      selection = await selectEndpoint(availableEndpoints, model, estimatedInputTokens)
    }
    
    if (!selection) {
      return errorResponse('所有模型的今日 token 配额已用尽', 429, { limit: DAILY_TOKEN_LIMIT })
    }
    
    const { endpoint, modelName, switchedFrom } = selection
    const currentUsage = await getTodayTokenUsage(modelName)
    const currentSearchUsage = await getMonthlySearchUsage()
    const apiType = getApiTypeByModelName(modelName)

    console.log('Selected model:', modelName, 'API type:', apiType)

    // Bot API (DeepSeek-R1)
    if (apiType === 'bot') {
      console.log('=== Bot API Request ===')
      console.log('URL:', BOT_API_URL)
      console.log('Bot ID:', endpoint)
      console.log('Model:', modelName)
      console.log('Stream:', stream)
      console.log('======================')
      
      const response = await fetch(BOT_API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${API_KEY}`,
        },
        body: JSON.stringify({
          model: endpoint,
          messages,
          stream: stream,
          stream_options: stream ? { include_usage: true } : undefined,
        }),
      })

      console.log('=== Bot API Response ===')
      console.log('Status:', response.status, response.statusText)
      console.log('========================')

      if (!response.ok) {
        const errorText = await response.text()
        console.error('Bot API Error:', errorText)
        return errorResponse(`HTTP ${response.status}: ${errorText}`, response.status)
      }

      if (stream) {
        return handleBotStream(response, endpoint, estimatedInputTokens, switchedFrom)
      }

      const data = await response.json() as DoubaoResponse

      if (data.error) {
        return errorResponse(data.error.message, 500)
      }

      if (!data.choices?.length) {
        return errorResponse('No response from model', 500)
      }

      const actualTokens = data.usage?.total_tokens || estimatedInputTokens
      await recordTokenUsage(modelName, actualTokens)

      return jsonResponse({
        choices: data.choices,
        usage: {
          ...data.usage,
          daily_usage: currentUsage + actualTokens,
          daily_limit: DAILY_TOKEN_LIMIT,
        },
        model: modelName,
        switched_from: switchedFrom,
      })
    }

    // Responses API (with or without search)
    if (apiType === 'responses' || enable_search) {
      const input = messages.map(msg => {
        let contentText: string = ''
        if (typeof msg.content === 'string') {
          contentText = msg.content
        } else if (Array.isArray(msg.content)) {
          const textPart = msg.content.find(p => p.type === 'text' && p.text)
          contentText = textPart?.text || ''
        }
        
        return {
          role: msg.role,
          content: [{
            type: "input_text",
            text: contentText
          }]
        }
      }).filter(msg => msg.content[0]?.text)
      
      const requestBody: Record<string, unknown> = {
        model: endpoint,
        input: input,
        stream: stream,
      }
      
      if (enable_search) {
        requestBody.tools = [{
          type: "web_search",
          sources: [],
        }]
      }
      
      console.log('=== Responses API Request ===')
      console.log('URL:', RESPONSES_API_URL)
      console.log('Model:', endpoint)
      console.log('Input:', JSON.stringify(input, null, 2))
      console.log('Tools:', JSON.stringify(requestBody.tools, null, 2))
      console.log('Stream:', stream)
      console.log('=============================')
      
      const response = await fetch(RESPONSES_API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${API_KEY}`,
        },
        body: JSON.stringify(requestBody),
      })

      console.log('=== Responses API Response ===')
      console.log('Status:', response.status, response.statusText)
      console.log('Content-Type:', response.headers.get('content-type'))
      console.log('==============================')

      if (!response.ok) {
        const errorText = await response.text()
        console.error('API Error Response:', errorText)
        return errorResponse(`HTTP ${response.status}: ${errorText}`, response.status)
      }

      if (stream) {
        return handleResponsesStream(response, endpoint, estimatedInputTokens, switchedFrom)
      }

      const data = await response.json() as DoubaoResponse

      if (data.error) {
        return errorResponse(data.error.message, 500)
      }

      const outputText = data.output?.text || ''
      const toolUsage = data.usage?.tool_usage || 0
      
      const actualTokens = data.usage?.total_tokens || Math.ceil(outputText.length / 4)
      await recordTokenUsage(modelName, actualTokens)
      
      if (toolUsage > 0) {
        await recordSearchUsage(toolUsage)
      }

      return jsonResponse({
        output: data.output,
        usage: {
          ...data.usage,
          daily_usage: currentUsage + actualTokens,
          daily_limit: DAILY_TOKEN_LIMIT,
          monthly_search_usage: currentSearchUsage + toolUsage,
          monthly_search_limit: MONTHLY_SEARCH_LIMIT,
        },
        model: modelName,
        switched_from: switchedFrom,
      })
    }

    // Chat API (default)

    const requestBody: Record<string, unknown> = {
      model: endpoint,
      messages,
      temperature: type === 'vision' ? 0.1 : 0.7,
      max_tokens: type === 'vision' ? 4096 : 2048,
      stream: stream,
    }

    const response = await fetch(API_BASE_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${API_KEY}`,
      },
      body: JSON.stringify(requestBody),
    })

    if (!response.ok) {
      const errorText = await response.text()
      return errorResponse(`HTTP ${response.status}: ${errorText}`, response.status)
    }

    if (stream) {
      return handleStreamResponse(response, endpoint, estimatedInputTokens, switchedFrom, enable_search)
    }

    const data = await response.json() as DoubaoResponse

    if (data.error) {
      return errorResponse(data.error.message, 500)
    }

    if (!data.choices?.length) {
      return errorResponse('No response from model', 500)
    }

    const actualTokens = data.usage?.total_tokens || estimatedInputTokens
    await recordTokenUsage(modelName, actualTokens)

    return jsonResponse({
      choices: data.choices,
      usage: {
        ...data.usage,
        daily_usage: currentUsage + actualTokens,
        daily_limit: DAILY_TOKEN_LIMIT,
        monthly_search_usage: currentSearchUsage,
        monthly_search_limit: MONTHLY_SEARCH_LIMIT,
      },
      model: modelName,
      switched_from: switchedFrom,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return errorResponse(message, 500)
  }
})
