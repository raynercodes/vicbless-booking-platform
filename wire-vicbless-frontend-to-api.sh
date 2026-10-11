#!/usr/bin/env bash
# Vicbless: connect the website to the real backend (build 2026-10-11 a). Run from the REPO ROOT:  bash wire-vicbless-frontend-to-api.sh
#
# What it does (all under frontend/):
#   ADDS     src/lib/{errors,mode,http,realApi}.js and src/admin/{realAdminApi,adminApi}.js, plus tests for both clients
#   MOVES    the current src/lib/api.js to src/lib/mockApi.js (the mock keeps working for npm run dev and the tests)
#            and puts a small switch in src/lib/api.js: production builds use the real API, dev and tests use the mock
#   EDITS    one-line imports in the admin screens, the sign-in note, the dashboard "Preview data" banner (mock only),
#            the booking page (shows the API's own messages), the Cancel dialog wording (the customer IS emailed now)
#   REPLACES vite.config.js (adds an optional dev proxy to a local backend), only if it is still the version I gave you
#   APPENDS  a "Mock data vs the real API" section to README.md
# It checks every edit BEFORE writing anything, so a file that does not look as expected stops it with nothing changed.
# FORCE=1 overrides the checks for the two whole-file replacements. It runs no git commands. Safe to run twice.
set -euo pipefail
if [ ! -d .git ] || [ ! -f frontend/src/lib/api.js ] || [ ! -d frontend/src/admin ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and frontend/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$(dirname 'lib/errors.js')"
cat > "$STAGE/lib/errors.js" <<'VICBLESS_EOF'
// Errors shared by the mock and the real data layer, so the pages can catch one kind of error
// whichever layer is behind them.

// The time a customer picked is no longer free (somebody got there first, or it has passed).
// Book.jsx catches this one: it sends the customer back to the time grid with fresh availability.
export class SlotTakenError extends Error {
  constructor(message = 'That time was just taken.') {
    super(message)
    this.name = 'SlotTakenError'
  }
}

// Backend error codes whose message was written to be read by a person, so the pages show it as it is.
// (Anything else, like a 500, gets the pages' own generic wording instead of a technical message.)
const FRIENDLY = new Set(['validation_error', 'invalid_slot', 'too_many_bookings', 'too_many_attempts', 'unauthorized'])

// Anything the real API (or the network on the way to it) answers with an error.
//   status   HTTP status, or 0 when the server could not be reached at all
//   apiCode  the backend's word for it: 'slot_taken', 'conflict', 'validation_error', 'network', ...
//   code     same as apiCode, except the admin screens use the older 'CONFLICT' / 'INVALID' words
//            (see realAdminApi.js), so that is the one they branch on
//   field    which input the message is about, when the backend says (validation errors)
//   friendly true when `message` is safe and useful to show as it is
export class ApiError extends Error {
  constructor({ status, code, message, field }) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.apiCode = code
    this.code = code
    this.field = field || ''
    this.friendly = FRIENDLY.has(code)
  }
}
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'lib/mode.js')"
cat > "$STAGE/lib/mode.js" <<'VICBLESS_EOF'
// Which data layer the site uses: 'real' talks to the backend API, 'mock' fakes everything in the browser.
//
//   production build (npm run build)   real
//   npm run dev, npm test              mock   (no backend needed)
//   VITE_API_MODE=real npm run dev     real   (with the dev proxy, see vite.config.js)
//
// The choice is made while the site is built, so a live site can never end up on the mock by accident.

const forced = import.meta.env.VITE_API_MODE
export const API_MODE = forced === 'mock' || forced === 'real' ? forced : import.meta.env.PROD ? 'real' : 'mock'
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'lib/http.js')"
cat > "$STAGE/lib/http.js" <<'VICBLESS_EOF'
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
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'lib/realApi.js')"
cat > "$STAGE/lib/realApi.js" <<'VICBLESS_EOF'
// The real customer-facing data layer: the same functions as mockApi.js, backed by the API.
//
//   getAvailability(dateKeys) -> GET  /api/availability?from=&to=
//   createBooking(data)       -> POST /api/bookings
//
// Return shapes match the mock exactly, so the pages do not know which one they are talking to.

import { fromKey, keyOf } from './availability.js'
import { ApiError, SlotTakenError } from './errors.js'
import { request } from './http.js'

// The API answers for at most this many days per call (shop.MAX_RANGE_DAYS in the backend).
const MAX_DAYS_PER_CALL = 31

function addDays(dateKey, n) {
  const d = fromKey(dateKey)
  d.setDate(d.getDate() + n)
  return keyOf(d)
}

// What the customer pages need to know about each day: which times are taken, and whether the whole
// day is off. One call covers the whole range; a longer range is split so the API never refuses it.
export async function getAvailability(dateKeys) {
  const keys = [...dateKeys].sort()
  const result = {}
  if (keys.length === 0) return result

  let from = keys[0]
  const last = keys[keys.length - 1]
  const calls = []
  while (from <= last) {
    const to = addDays(from, MAX_DAYS_PER_CALL - 1) < last ? addDays(from, MAX_DAYS_PER_CALL - 1) : last
    calls.push(request('GET', `/availability?from=${from}&to=${to}`))
    from = addDays(to, 1)
  }
  for (const part of await Promise.all(calls)) Object.assign(result, part)

  // A day the API says nothing about is treated as completely free, never as an error.
  return Object.fromEntries(keys.map((k) => [k, result[k] || { busy: [], dayOff: false }]))
}

// Just the taken times (the admin mock uses this one; kept so both layers have the same exports).
export async function getBusy(dateKeys) {
  const availability = await getAvailability(dateKeys)
  return Object.fromEntries(Object.entries(availability).map(([k, v]) => [k, v.busy]))
}

// Books the time. Resolves to the booking, which has everything the "You're booked" screen shows.
// The API's answer has no name (it only returns what a stranger could safely be told), so what the
// customer typed is merged back in. The API's code/date/time win, they are what was actually saved.
export async function createBooking(payload) {
  try {
    const saved = await request('POST', '/bookings', {
      body: {
        staffId: payload.staffId,
        serviceId: payload.serviceId,
        dateKey: payload.dateKey,
        start: payload.start,
        name: payload.name,
        phone: payload.phone,
        email: payload.email,
        notes: payload.notes,
        // `minutes` is deliberately not sent: the API looks the length up from the service.
      },
    })
    return { ...payload, ...saved }
  } catch (err) {
    // Both mean "pick another time": taken by somebody else, or no longer bookable (already past, too soon).
    if (err instanceof ApiError && (err.apiCode === 'slot_taken' || err.apiCode === 'slot_unavailable')) {
      throw new SlotTakenError(err.message)
    }
    throw err
  }
}
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'lib/realApi.test.js')"
cat > "$STAGE/lib/realApi.test.js" <<'VICBLESS_EOF'
// The real data layer against a pretend fetch: what it sends, how it reads answers, how it reports failures.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, SlotTakenError } from './errors.js'
import { createBooking, getAvailability } from './realApi.js'

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const errorBody = (code, message, field) => ({ error: { code, message, ...(field ? { field } : {}) } })

let calls
beforeEach(() => {
  calls = []
})
afterEach(() => vi.unstubAllGlobals())
const stub = (...answers) => {
  const queue = [...answers]
  vi.stubGlobal('fetch', vi.fn(async (url, init) => {
    calls.push({ url, init })
    const next = queue.length > 1 ? queue.shift() : queue[0]
    if (typeof next === 'function') return next(url, init)
    return next.clone() // a Response body can be read once; every call gets its own copy
  }))
}

const payload = {
  staffId: 'vic', serviceId: 'haircut', dateKey: '2026-10-13', start: 660, minutes: 35,
  name: 'Marcus Jones', phone: '(555) 010-1234', email: '', notes: '',
}

describe('getAvailability', () => {
  it('asks for the whole range in one call and fills in days the API did not mention', async () => {
    stub(json(200, { '2026-10-13': { busy: [660], dayOff: false } }))
    const out = await getAvailability(['2026-10-14', '2026-10-13', '2026-10-15'])
    expect(calls).toHaveLength(1)
    expect(calls[0].url).toBe('/api/availability?from=2026-10-13&to=2026-10-15')
    expect(out['2026-10-13']).toEqual({ busy: [660], dayOff: false })
    expect(out['2026-10-14']).toEqual({ busy: [], dayOff: false })
    expect(Object.keys(out).sort()).toEqual(['2026-10-13', '2026-10-14', '2026-10-15'])
  })

  it('splits a range longer than the API allows (31 days)', async () => {
    stub(json(200, {}))
    await getAvailability(['2026-11-01', '2026-12-10'])
    expect(calls.length).toBe(2)
    expect(calls[0].url).toBe('/api/availability?from=2026-11-01&to=2026-12-01')
    expect(calls[1].url).toBe('/api/availability?from=2026-12-02&to=2026-12-10')
  })

  it('returns an empty answer without calling the API when no days are asked for', async () => {
    stub(json(200, {}))
    expect(await getAvailability([])).toEqual({})
    expect(calls).toHaveLength(0)
  })

  it('fails with an ApiError that has a readable message when the server cannot be reached', async () => {
    stub(() => { throw new TypeError('Failed to fetch') })
    await expect(getAvailability(['2026-10-13'])).rejects.toMatchObject({ name: 'ApiError', apiCode: 'network', status: 0 })
  })
})

describe('createBooking', () => {
  it('sends the booking without `minutes`, and merges what the customer typed into the reply', async () => {
    stub(json(201, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic' }))
    const booking = await createBooking(payload)
    expect(calls[0].url).toBe('/api/bookings')
    expect(calls[0].init.method).toBe('POST')
    const sent = JSON.parse(calls[0].init.body)
    expect(sent).not.toHaveProperty('minutes')
    expect(sent).toMatchObject({ serviceId: 'haircut', dateKey: '2026-10-13', start: 660, name: 'Marcus Jones' })
    expect(booking).toMatchObject({ code: 'ABC23', name: 'Marcus Jones', serviceId: 'haircut', start: 660 })
  })

  it('treats a repeat of the same booking (200) as success', async () => {
    stub(json(200, { code: 'ABC23', dateKey: '2026-10-13', start: 660, minutes: 35, serviceId: 'haircut', staffId: 'vic' }))
    expect((await createBooking(payload)).code).toBe('ABC23')
  })

  it.each(['slot_taken', 'slot_unavailable'])('turns %s into SlotTakenError', async (code) => {
    stub(json(409, errorBody(code, 'Sorry, that time was just taken. Please pick another.')))
    const err = await createBooking(payload).catch((e) => e)
    expect(err).toBeInstanceOf(SlotTakenError)
    expect(err.message).toMatch(/pick another/)
  })

  it.each([
    [422, 'validation_error', true],
    [422, 'invalid_slot', true],
    [429, 'too_many_bookings', true],
    [500, 'server_error', false],
  ])('keeps %i %s as an ApiError (friendly=%s)', async (status, code, friendly) => {
    stub(json(status, errorBody(code, 'Words for a person.', code === 'validation_error' ? 'phone' : undefined)))
    const err = await createBooking(payload).catch((e) => e)
    expect(err).toBeInstanceOf(ApiError)
    expect(err.apiCode).toBe(code)
    expect(err.friendly).toBe(friendly)
    if (code === 'validation_error') expect(err.field).toBe('phone')
  })

  it('does not show technical text when something other than the API answers (a CloudFront error page)', async () => {
    stub(new Response('<html>Bad gateway</html>', { status: 502 }))
    const err = await createBooking(payload).catch((e) => e)
    expect(err).toBeInstanceOf(ApiError)
    expect(err.status).toBe(502)
    expect(err.message).not.toMatch(/html|gateway/i)
    expect(err.friendly).toBe(false)
  })
})
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'admin/realAdminApi.js')"
cat > "$STAGE/admin/realAdminApi.js" <<'VICBLESS_EOF'
// The real admin data layer: the same functions as mockAdminApi.js, backed by the API.
//
//   signIn(password)          POST   /api/admin/login            -> a 12 hour token, kept in this browser
//   getDay(dateKey)           GET    /api/admin/schedule?date=
//   cancelBooking(item)       DELETE /api/admin/bookings/{id}    (the customer is emailed if they left an email)
//   moveBooking(item, to)     PATCH  /api/admin/bookings/{id}    (the booking comes back with a NEW id)
//   addBlock(block)           POST   /api/admin/blocks
//   removeBlock(id)           DELETE /api/admin/blocks/{id}
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
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'admin/realAdminApi.test.js')"
cat > "$STAGE/admin/realAdminApi.test.js" <<'VICBLESS_EOF'
// The real admin data layer against a pretend fetch: the token, the URLs, and what happens when it expires.
// Runs in plain Node (no jsdom needed): a tiny in-memory localStorage and a window that can dispatch events stand in.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { addBlock, cancelBooking, getDay, isSignedIn, moveBooking, removeBlock, SIGNED_OUT_EVENT, signIn, signOut } from './realAdminApi.js'

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const errorBody = (code, message) => ({ error: { code, message } })
let calls

// An in-memory stand-in for the browser's localStorage, and a window that can send and hear events.
function installBrowserStubs() {
  const data = new Map()
  vi.stubGlobal('localStorage', {
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, String(v)),
    removeItem: (k) => data.delete(k),
    clear: () => data.clear(),
  })
  vi.stubGlobal('window', new EventTarget())
}
const stub = (...answers) => {
  const queue = [...answers]
  vi.stubGlobal('fetch', vi.fn(async (url, init) => {
    calls.push({ url, init })
    return queue.length > 1 ? queue.shift() : queue[0]
  }))
}

beforeEach(() => {
  installBrowserStubs()
  calls = []
  localStorage.clear()
  signOut()
})
afterEach(() => vi.unstubAllGlobals())

async function signedIn() {
  stub(json(200, { token: 'tok123', expiresIn: 43200 }))
  await signIn('hunter2')
  calls = []
}

describe('signing in', () => {
  it('posts the password, keeps the token, and sends it on later calls', async () => {
    stub(json(200, { token: 'tok123', expiresIn: 43200 }))
    expect(isSignedIn()).toBe(false)
    await signIn('hunter2')
    expect(calls[0].url).toBe('/api/admin/login')
    expect(JSON.parse(calls[0].init.body)).toEqual({ password: 'hunter2' })
    expect(isSignedIn()).toBe(true)

    calls = []
    stub(json(200, { dateKey: '2026-10-13', items: [], blocks: [] }))
    await getDay('2026-10-13')
    expect(calls[0].url).toBe('/api/admin/schedule?date=2026-10-13')
    expect(calls[0].init.headers.Authorization).toBe('Bearer tok123')
  })

  it('rejects an empty password without calling the API', async () => {
    stub(json(200, {}))
    await expect(signIn('   ')).rejects.toThrow('Enter your password.')
    expect(calls).toHaveLength(0)
  })

  it("shows the API's message for a wrong password, and does not fire the signed-out event", async () => {
    const out = vi.fn()
    window.addEventListener(SIGNED_OUT_EVENT, out)
    stub(json(401, errorBody('unauthorized', "That password isn't right. Check it and try again.")))
    await expect(signIn('nope')).rejects.toThrow("That password isn't right")
    expect(out).not.toHaveBeenCalled()
    expect(isSignedIn()).toBe(false)
    window.removeEventListener(SIGNED_OUT_EVENT, out)
  })

  it('treats an expired saved token as signed out', () => {
    localStorage.setItem('vicbless.admin.token', JSON.stringify({ token: 'old', expiresAt: Date.now() - 1000 }))
    expect(isSignedIn()).toBe(false)
  })

  it('ignores the old mock session marker', () => {
    localStorage.setItem('vicbless.admin.session', 'preview')
    expect(isSignedIn()).toBe(false)
  })
})

describe('signed-in calls', () => {
  it('uses the right method and URL for each action, encoding ids', async () => {
    await signedIn()
    stub(json(200, { cancelled: true }))
    await cancelBooking({ id: '2026-10-13.0660.9f3a1c2b' })
    expect([calls[0].init.method, calls[0].url]).toEqual(['DELETE', '/api/admin/bookings/2026-10-13.0660.9f3a1c2b'])

    calls = []
    stub(json(200, { id: '2026-10-14.0700.aaaaaaaa', code: 'ABC23' }))
    const moved = await moveBooking({ id: '2026-10-13.0660.9f3a1c2b' }, { dateKey: '2026-10-14', start: 700 })
    expect([calls[0].init.method, calls[0].url]).toEqual(['PATCH', '/api/admin/bookings/2026-10-13.0660.9f3a1c2b'])
    expect(JSON.parse(calls[0].init.body)).toEqual({ dateKey: '2026-10-14', start: 700 })
    expect(moved.id).toBe('2026-10-14.0700.aaaaaaaa') // the NEW id

    calls = []
    stub(json(201, { id: 'b1', dateKey: '2026-10-13', start: 600, end: 700, note: 'Lunch', whole: false }))
    await addBlock({ dateKey: '2026-10-13', start: 600, end: 700, note: 'Lunch' })
    expect([calls[0].init.method, calls[0].url]).toEqual(['POST', '/api/admin/blocks'])

    calls = []
    stub(json(200, { removed: true }))
    await removeBlock('b/1')
    expect([calls[0].init.method, calls[0].url]).toEqual(['DELETE', '/api/admin/blocks/b%2F1'])
  })

  it("gives the screens their 'CONFLICT' and 'INVALID' words", async () => {
    await signedIn()
    stub(json(409, errorBody('conflict', 'That overlaps a booking or time you already blocked off.')))
    expect(await addBlock({ dateKey: '2026-10-13', start: 600, end: 700 }).catch((e) => e)).toMatchObject({ code: 'CONFLICT', apiCode: 'conflict' })
    stub(json(409, errorBody('slot_taken', 'Sorry, that time was just taken. Please pick another.')))
    expect(await moveBooking({ id: 'x' }, { dateKey: '2026-10-13', start: 600 }).catch((e) => e)).toMatchObject({ code: 'CONFLICT' })
    stub(json(422, errorBody('invalid_slot', 'That isn’t a time Vic takes bookings for.')))
    expect(await moveBooking({ id: 'x' }, { dateKey: '2026-10-13', start: 601 }).catch((e) => e)).toMatchObject({ code: 'INVALID' })
  })

  it('drops the session and announces it when the API says 401', async () => {
    await signedIn()
    const out = vi.fn()
    window.addEventListener(SIGNED_OUT_EVENT, out)
    stub(json(401, errorBody('unauthorized', 'Please sign in to continue.')))
    await expect(getDay('2026-10-13')).rejects.toMatchObject({ status: 401 })
    expect(out).toHaveBeenCalledTimes(1)
    expect(isSignedIn()).toBe(false)
    window.removeEventListener(SIGNED_OUT_EVENT, out)
  })

  it('does not even call the API when there is no session', async () => {
    stub(json(200, {}))
    await expect(getDay('2026-10-13')).rejects.toMatchObject({ status: 401 })
    expect(calls).toHaveLength(0)
  })
})
VICBLESS_EOF
mkdir -p "$STAGE/$(dirname 'admin/adminApi.js')"
cat > "$STAGE/admin/adminApi.js" <<'VICBLESS_EOF'
// Vic's dashboard data layer. The admin screens import from HERE and never know which layer answers.
// real -> realAdminApi.js (the backend, production builds); mock -> mockAdminApi.js (npm run dev and tests).
// See ../lib/mode.js for how the choice is made.

import { API_MODE } from '../lib/mode.js'
import * as mock from './mockAdminApi.js'
import * as real from './realAdminApi.js'

const layer = API_MODE === 'real' ? real : mock

export const isSignedIn = () => layer.isSignedIn()
export const signIn = (password) => layer.signIn(password)
export const signOut = () => layer.signOut()
export const getDay = (dateKey) => layer.getDay(dateKey)
export const cancelBooking = (item) => layer.cancelBooking(item)
export const moveBooking = (item, to) => layer.moveBooking(item, to)
export const addBlock = (block) => layer.addBlock(block)
export const removeBlock = (id) => layer.removeBlock(id)
export { SIGNED_OUT_EVENT } from './realAdminApi.js'
VICBLESS_EOF
cat > "$STAGE/FACADE" <<'VICBLESS_EOF'
// The customer-facing data layer. The pages import from HERE and never know which layer answers.
//
//   real  -> realApi.js, the backend (production builds)
//   mock  -> mockApi.js, fake data kept in the browser (npm run dev and the tests)
//
// See mode.js for how the choice is made. Both layers export the same functions with the same shapes.

import * as mock from './mockApi.js'
import { API_MODE } from './mode.js'
import * as real from './realApi.js'

const layer = API_MODE === 'real' ? real : mock

export { SlotTakenError } from './errors.js'
export const getAvailability = (dateKeys) => layer.getAvailability(dateKeys)
export const getBusy = (dateKeys) => layer.getBusy(dateKeys)
export const createBooking = (payload) => layer.createBooking(payload)
VICBLESS_EOF
cat > "$STAGE/VITE" <<'VICBLESS_EOF'
import { defineConfig, loadEnv } from 'vite'

// npm run dev uses the in-browser mock by default. To try the site against a real backend, point the dev
// server's /api at it (the site and the API share one address in production, so this mirrors that):
//   VITE_API_MODE=real VITE_API_PROXY=http://127.0.0.1:8000 npm run dev
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_')
  return {
    esbuild: { jsx: 'automatic' },
    server: env.VITE_API_PROXY ? { proxy: { '/api': { target: env.VITE_API_PROXY, changeOrigin: true } } } : {},
    test: { environment: 'node', server: { deps: { inline: [/@testing-library/] } } },
  }
})
VICBLESS_EOF
cat > "$STAGE/README_SECTION" <<'VICBLESS_EOF'
## Mock data vs the real API

The site has two data layers behind the same functions, so the pages never know which one they are using:

| Layer | Files | Used when |
| --- | --- | --- |
| Mock (fake data kept in the browser) | `lib/mockApi.js`, `lib/mockStore.js`, `admin/mockAdminApi.js` | `npm run dev` and `npm test` |
| Real (the backend API) | `lib/realApi.js`, `admin/realAdminApi.js`, `lib/http.js` | production builds (`npm run build`, the deploy workflow) |

The pages import from `lib/api.js` and `admin/adminApi.js`, which pick the layer (see `lib/mode.js`).
The choice is made while the site is built, so a live site cannot end up on the mock by accident.

Try the site against a real backend while developing. Start the API on port 8000, then:

```bash
VITE_API_MODE=real VITE_API_PROXY=http://127.0.0.1:8000 npm run dev
```

The site and the API share one address in production (CloudFront sends `/api/*` to the backend), so every
call is a relative `/api/...` URL and the dev server forwards `/api` the same way. There is no API address to configure.
VICBLESS_EOF
export STAGE
python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

stage = Path(os.environ["STAGE"]); force = os.environ.get("FORCE") == "1"
fe = Path("frontend"); src = fe / "src"
sha = lambda text: hashlib.sha256(text.encode()).hexdigest()
NEW_FILES = ['lib/errors.js', 'lib/mode.js', 'lib/http.js', 'lib/realApi.js', 'lib/realApi.test.js', 'admin/realAdminApi.js', 'admin/realAdminApi.test.js', 'admin/adminApi.js']
KNOWN_OLD_API = ['30b5880fbc2fdebb5cdd8e8a7111a15fc62ca0e371b94c792a07daa2e58e69be', 'acea3bd2da4926d12d782d1d6ad4dfdfa625ecb9c21d6b67214c888e41909110']
KNOWN_OLD_VITE = ['2a6811f865ee2d6a424cef6d34959ee137028895136a9799eda025e972d6cb12', '634beb6b10f0e57dd2bea75529b4baca82eed9edd2509b60eee356c07b944c59']
PATCHES = json.loads('[["lib/mockApi.js", "export class SlotTakenError extends Error {\\n  constructor() {\\n    super(\'That time was just taken.\')\\n    this.name = \'SlotTakenError\'\\n  }\\n}\\n", "// SlotTakenError lives in errors.js, shared with the real data layer.\\n"], ["lib/mockApi.js", "import { HOURS, SLOT_MINUTES } from \'../config.js\'\\n", "import { HOURS, SLOT_MINUTES } from \'../config.js\'\\nimport { SlotTakenError } from \'./errors.js\'\\n"], ["lib/mockApi.js", "// Mock data layer. This is the ONLY file to replace when the backend exists.\\n", "// MOCK customer data layer, used by npm run dev and the tests (see api.js and mode.js). The real one is realApi.js.\\n"], ["admin/mockAdminApi.js", "import { getBusy } from \'../lib/api.js\'\\n", "import { getBusy } from \'../lib/mockApi.js\'\\n"], ["admin/Schedule.jsx", "import { cancelBooking, getDay, removeBlock } from \'./mockAdminApi.js\'\\n", "import { cancelBooking, getDay, removeBlock } from \'./adminApi.js\'\\n"], ["admin/Schedule.jsx", "The time opens up for other customers. The customer is not\\n          told yet.", "The time opens up for other customers. If they left an\\n          email, they are told it was cancelled."], ["admin/BlockOff.jsx", "import { addBlock } from \'./mockAdminApi.js\'\\n", "import { addBlock } from \'./adminApi.js\'\\n"], ["admin/MoveBooking.jsx", "import { moveBooking } from \'./mockAdminApi.js\'\\n", "import { moveBooking } from \'./adminApi.js\'\\n"], ["admin/SignIn.jsx", "import { signIn } from \'./mockAdminApi.js\'\\n", "import { API_MODE } from \'../lib/mode.js\'\\nimport { signIn } from \'./adminApi.js\'\\n"], ["admin/SignIn.jsx", "      <p className=\\"admin-preview-note\\">Preview: any password works until the backend is connected.</p>\\n", "      {API_MODE === \'mock\' && <p className=\\"admin-preview-note\\">Preview: any password works until the backend is connected.</p>}\\n"], ["admin/Admin.jsx", "import { isSignedIn, signOut } from \'./mockAdminApi.js\'\\n", "import { API_MODE } from \'../lib/mode.js\'\\nimport { SIGNED_OUT_EVENT, isSignedIn, signOut } from \'./adminApi.js\'\\n"], ["admin/Admin.jsx", "  // Keep the page out of search results,", "  // The session ran out (or the API refused it): back to the sign-in screen instead of a dashboard that cannot load.\\n  useEffect(() => {\\n    const out = () => setSignedIn(false)\\n    window.addEventListener(SIGNED_OUT_EVENT, out)\\n    return () => window.removeEventListener(SIGNED_OUT_EVENT, out)\\n  }, [])\\n\\n  // Keep the page out of search results,"], ["admin/Admin.jsx", "      <p className=\\"admin-preview-note\\">\\n        Preview data. Bookings made on the site in this browser show up here, along with sample ones marked \\"sample\\". Cancelling and blocking time work too, and are saved in this browser only.\\n      </p>\\n", "      {API_MODE === \'mock\' && (\\n        <p className=\\"admin-preview-note\\">\\n          Preview data. Bookings made on the site in this browser show up here, along with sample ones marked \\"sample\\". Cancelling and blocking time work too, and are saved in this browser only.\\n        </p>\\n      )}\\n"], ["pages/Book.jsx", "        setNotice(\\n          <>\\n            Something went wrong saving your booking. Try again, or call <PhoneLink />.\\n          </>,\\n        )", "        // A message the API wrote for customers (a bad phone number, too many bookings) is shown as it is.\\n        setNotice(\\n          ex && ex.friendly ? (\\n            ex.message\\n          ) : (\\n            <>\\n              Something went wrong saving your booking. Try again, or call <PhoneLink />.\\n            </>\\n          ),\\n        )"]]')
MARK = "## Mock data vs the real API"

def stop(msg):
    print("Stopped. " + msg)
    print("Nothing was changed. Tell me what differs, or run with FORCE=1 where that applies.")
    sys.exit(1)

writes = {}   # path -> new text, applied only after every check passed

# 1. lib/api.js -> lib/mockApi.js + the switch
api = src / "lib" / "api.js"; mock = src / "lib" / "mockApi.js"
facade = (stage / "FACADE").read_text().rstrip("\n") + "\n"
cur = api.read_text()
if sha(cur) == sha(facade):
    pass  # already switched
elif sha(cur) in KNOWN_OLD_API or force:
    if not mock.exists():
        writes[mock] = cur  # the mock is the CURRENT api.js; the patches below then adjust it
    writes[api] = facade
else:
    stop("frontend/src/lib/api.js is not the mock version this script expects (was it edited?).")

# 2. anchor patches: each old text must appear exactly once, unless the new text is already there
def current_text(path):
    return writes[path] if path in writes else path.read_text()
for rel, old, new in PATCHES:
    path = src / rel
    if path not in writes and not path.exists():
        stop(f"{path} does not exist.")
    text = current_text(path)
    if new in text:
        continue
    if text.count(old) != 1:
        stop(f"{path} does not contain the line I need to change exactly once (it has {text.count(old)}). Was it edited?")
    writes[path] = text.replace(old, new)

# 3. vite.config.js (optional: only the dev proxy needs it)
vite = fe / "vite.config.js"; vite_new = (stage / "VITE").read_text().rstrip("\n") + "\n"
vcur = vite.read_text() if vite.exists() else ""
vite_note = None
if sha(vcur) == sha(vite_new):
    pass
elif sha(vcur) in KNOWN_OLD_VITE or force:
    writes[vite] = vite_new
else:
    vite_note = "frontend/vite.config.js was edited, so I left it alone. It only matters for trying the site against a local backend."

# 4. new files and the README section
for rel in NEW_FILES:
    new_text = (stage / rel).read_text().rstrip("\n") + "\n"
    path = src / rel
    if not path.exists() or path.read_text() != new_text:
        writes[path] = new_text
readme = fe / "README.md"
section = (stage / "README_SECTION").read_text().strip("\n") + "\n"
if readme.exists() and MARK not in readme.read_text():
    writes[readme] = readme.read_text().rstrip("\n") + "\n\n" + section

# 5. write everything
for path, text in writes.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
if writes:
    print("Wrote:")
    for path in sorted(writes): print("  -", path)
else:
    print("Already up to date. Nothing to change.")
if vite_note: print("Note:", vite_note)
PY
echo
echo "Next:  cd frontend && npm test        (the old tests plus the new client tests should all pass)"
echo "Then:  git add -A && git commit, and push to dev: the deploy workflow builds the site in REAL mode."
echo "After it deploys, open the site and book a time, then sign in at /#/vic with Vic's password to see it."
