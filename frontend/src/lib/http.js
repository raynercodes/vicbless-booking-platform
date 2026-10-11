// One small wrapper around fetch for every call to the backend.
//
// The site and the API share one address (CloudFront sends /api/* to the backend), so every call is
// a relative '/api/...' URL: no CORS, and no API address to configure.
//
// What it guarantees to the code that calls it:
//   - success returns the parsed JSON
//   - ANY failure throws an ApiError (never a raw TypeError or a half-parsed response), with a message
//     that is safe to show: the backend's own message when it sent one, a plain sentence otherwise
//   - a request that hangs gives up after `timeoutMs` instead of leaving a spinner forever

import { ApiError } from './errors.js'

const TIMEOUT_MS = 15000
const NETWORK_MESSAGE = 'Could not reach the server. Check your connection and try again.'
const SERVER_MESSAGE = 'Something went wrong on our side. Please try again in a moment.'

export async function request(method, path, { body, token, timeoutMs = TIMEOUT_MS } = {}) {
  const headers = { Accept: 'application/json' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (token) headers.Authorization = `Bearer ${token}`

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  let response
  try {
    response = await fetch(`/api${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    })
  } catch {
    // offline, DNS, the request was aborted by the timeout, ...
    throw new ApiError({ status: 0, code: 'network', message: NETWORK_MESSAGE })
  } finally {
    clearTimeout(timer)
  }

  // The body is JSON from the API. From anything else in the way (a CloudFront error page, say) it is not.
  let data = null
  try {
    data = await response.json()
  } catch {
    /* not JSON: handled below */
  }

  if (response.ok) {
    if (data === null) throw new ApiError({ status: response.status, code: 'bad_response', message: SERVER_MESSAGE })
    return data
  }

  const err = data && typeof data === 'object' ? data.error : null
  throw new ApiError({
    status: response.status,
    code: err && typeof err.code === 'string' ? err.code : 'server_error',
    message: err && typeof err.message === 'string' && err.message ? err.message : SERVER_MESSAGE,
    field: err && err.field,
  })
}
