// The real admin data layer: the same functions as mockAdminApi.js, backed by the API.
//
//   signIn(password)          POST   /api/admin/login            -> a 12 hour token, kept in this browser
//   getDay(dateKey)           GET    /api/admin/schedule?date=
//   cancelBooking(item)       DELETE /api/admin/bookings/{id}    (the customer is emailed if they left an email)
//   moveBooking(item, to)     PATCH  /api/admin/bookings/{id}    (the booking comes back with a NEW id)
//   addBlock(block)           POST   /api/admin/blocks
//   removeBlock(id)           DELETE /api/admin/blocks/{id}
//   getAdminSettings()        GET    /api/admin/settings
//   saveSettings(body)        PUT    /api/admin/settings       (the saved settings come back)
//
// Errors thrown to the screens: an ApiError whose `.code` is 'CONFLICT' when the time is taken or
// overlaps something, 'INVALID' when it is not a time Vic works, and the API's own word otherwise.
// If the session has run out (the API says 401 on a signed-in call), the token is dropped and the
// dashboard is told to show the sign-in screen again.

import { ApiError } from '../lib/errors.js'
import { request } from '../lib/http.js'

const SESSION_KEY = 'vicbless.admin.token'
let memoryToken = null // the token also lives here, so signing in works even when storage is blocked
export const SIGNED_OUT_EVENT = 'vicbless:signed-out'

// The older screens branch on these two words, so they are kept.
const SCREEN_CODES = { conflict: 'CONFLICT', slot_taken: 'CONFLICT', slot_unavailable: 'CONFLICT', invalid_slot: 'INVALID' }

function readSession() {
  try {
    const saved = JSON.parse(localStorage.getItem(SESSION_KEY) || 'null')
    if (saved && typeof saved.token === 'string' && typeof saved.expiresAt === 'number' && saved.expiresAt > Date.now()) return saved
  } catch {
    /* unreadable or blocked: treated as signed out */
  }
  return null
}

export function isSignedIn() {
  return readSession() !== null
}

export function signOut() {
  try {
    localStorage.removeItem(SESSION_KEY)
  } catch {
    /* nothing to clear */
  }
}

export async function signIn(password) {
  if (!String(password ?? '').trim()) throw new Error('Enter your password.')
  const { token, expiresIn } = await request('POST', '/admin/login', { body: { password } })
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify({ token, expiresAt: Date.now() + expiresIn * 1000 }))
  } catch {
    /* storage blocked: the session just will not survive a reload */
  }
  memoryToken = { token, expiresAt: Date.now() + expiresIn * 1000 }
}

function currentToken() {
  const saved = readSession() || (memoryToken && memoryToken.expiresAt > Date.now() ? memoryToken : null)
  return saved ? saved.token : ''
}

// Every signed-in call goes through here.
async function call(method, path, body) {
  const token = currentToken()
  if (!token) {
    signedOut()
    throw new ApiError({ status: 401, code: 'unauthorized', message: 'Please sign in to continue.' })
  }
  try {
    return await request(method, path, { body, token })
  } catch (err) {
    if (err instanceof ApiError) {
      if (err.status === 401) signedOut()
      err.code = SCREEN_CODES[err.apiCode] || err.apiCode
    }
    throw err
  }
}

function signedOut() {
  signOut()
  memoryToken = null
  if (typeof window !== 'undefined') window.dispatchEvent(new Event(SIGNED_OUT_EVENT))
}

export function getDay(dateKey) {
  return call('GET', `/admin/schedule?date=${encodeURIComponent(dateKey)}`)
}

export async function cancelBooking(item) {
  await call('DELETE', `/admin/bookings/${encodeURIComponent(item.id)}`)
}

export async function moveBooking(item, { dateKey, start }) {
  return call('PATCH', `/admin/bookings/${encodeURIComponent(item.id)}`, { dateKey, start })
}

export function addBlock({ dateKey, start, end, note = '', whole = false }) {
  return call('POST', '/admin/blocks', { dateKey, start, end, note, whole })
}

export async function removeBlock(id) {
  await call('DELETE', `/admin/blocks/${encodeURIComponent(id)}`)
}

export function getAdminSettings() {
  return call('GET', '/admin/settings')
}

export function saveSettings(body) {
  return call('PUT', '/admin/settings', body)
}
