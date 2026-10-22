import { describe, it, expect } from 'vitest'
import { clearPending, loadPending, PENDING_KEY, readReturn, savePending } from './paymentReturn'

const fakeStorage = (initial = {}) => {
  const data = { ...initial }
  return {
    data,
    getItem: (k) => (k in data ? data[k] : null),
    setItem: (k, v) => {
      data[k] = v
    },
    removeItem: (k) => {
      delete data[k]
    },
  }
}

describe('reading the address Stripe sends people back to', () => {
  it('knows a paid booking', () => {
    expect(readReturn('#/book?paid=VB-K7M2QX')).toEqual({ kind: 'paid', code: 'VB-K7M2QX' })
  })
  it('knows a cancelled payment', () => {
    expect(readReturn('#/book?payment=cancelled')).toEqual({ kind: 'cancelled' })
  })
  it('ignores everything else', () => {
    for (const hash of ['', '#/book', '#/book?service=mens-cut', '#/book?paid=nonsense', '#/book?paid=<script>', undefined]) {
      expect(readReturn(hash)).toBe(null)
    }
  })
})

describe('remembering a booking while the customer is at Stripe', () => {
  const pending = { request: { serviceId: 'mens-cut', dateKey: '2026-10-21', time: 720, form: { name: 'A' } }, booking: { code: 'VB-AAAAAA' } }

  it('saves and loads it', () => {
    const s = fakeStorage()
    savePending(s, pending)
    expect(loadPending(s)).toEqual(pending)
  })
  it('forgets it', () => {
    const s = fakeStorage()
    savePending(s, pending)
    clearPending(s)
    expect(loadPending(s)).toBe(null)
  })
  it('treats damaged or half-saved data as nothing', () => {
    expect(loadPending(fakeStorage({ [PENDING_KEY]: '{oops' }))).toBe(null)
    expect(loadPending(fakeStorage({ [PENDING_KEY]: JSON.stringify({ request: {} }) }))).toBe(null)
  })
  it('does not break when storage is blocked or missing', () => {
    expect(() => savePending(null, pending)).not.toThrow()
    expect(loadPending(null)).toBe(null)
    const blocked = { getItem: () => { throw new Error('no') }, setItem: () => { throw new Error('no') }, removeItem: () => { throw new Error('no') } }
    expect(() => savePending(blocked, pending)).not.toThrow()
    expect(loadPending(blocked)).toBe(null)
    expect(() => clearPending(blocked)).not.toThrow()
  })
})
