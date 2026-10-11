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
