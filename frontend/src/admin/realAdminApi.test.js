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
