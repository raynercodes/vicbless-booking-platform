import { describe, it, expect } from 'vitest'
import { cancelMessage, money, paymentLabel, textsLabel, whoIsTold } from './notify'

const base = { name: 'Rayner Codes', smsConsent: false, email: '' }
const msg = (o) => cancelMessage({ ...base, ...o }, '3:05 pm', "Men's haircut with design")

describe('cancel message', () => {
  it('says text and email when both apply', () => {
    expect(msg({ smsConsent: true, email: 'a@b.co' })).toContain('a text and an email')
  })
  it('says text only when they only agreed to texts', () => {
    const m = msg({ smsConsent: true })
    expect(m).toContain('a text saying')
    expect(m).not.toContain('email')
  })
  it('says email only when they only left an email', () => {
    const m = msg({ email: 'a@b.co' })
    expect(m).toContain('an email saying')
    expect(m).not.toContain('a text')
  })
  it('says nobody is told when neither applies', () => {
    expect(msg({})).toContain("won't be told")
    expect(msg({ email: '   ' })).toContain("won't be told")
  })
  it('always names the booking and frees the time', () => {
    expect(msg({})).toMatch(/^Cancel Rayner Codes's 3:05 pm Men's haircut with design\? The time opens up/)
  })
  it('only a true consent counts', () => {
    expect(whoIsTold({ smsConsent: 'yes', email: '' }).text).toBe(false)
    expect(whoIsTold({ email: 'x@y.co' }).email).toBe(true)
  })
})

describe('texts label', () => {
  it('has a mark and words either way', () => {
    expect(textsLabel({ smsConsent: true })).toEqual({ mark: '✓', words: 'Text Reminders', on: true })
    expect(textsLabel({})).toEqual({ mark: '✗', words: 'No Text Reminders', on: false })
  })
})

describe('money', () => {
  it('writes dollars, with cents only when there are some', () => {
    expect(money(5500)).toBe('$55')
    expect(money(6550)).toBe('$65.50')
    expect(money(5)).toBe('$0.05')
  })
  it('says nothing for no amount', () => {
    for (const v of [0, -1, undefined, null, 12.5, '5500']) expect(money(v)).toBe('')
  })
})

describe('payment', () => {
  it('labels how the customer pays', () => {
    expect(paymentLabel({ payment: 'paid', amountCents: 5500 })).toEqual({ state: 'paid', mark: '✓', words: 'Paid online · $55' })
    expect(paymentLabel({ payment: 'shop', amountCents: 6500 })).toEqual({ state: 'shop', mark: '$', words: 'Pay at the shop · $65' })
    expect(paymentLabel({ payment: 'pending', amountCents: 5500 })).toMatchObject({ state: 'pending', words: 'Waiting for payment · $55' })
  })
  it('treats a booking from before payments existed as paying at the shop, with no amount', () => {
    expect(paymentLabel({})).toEqual({ state: 'shop', mark: '$', words: 'Pay at the shop' })
  })
  it('warns that a paid booking is refunded when cancelled', () => {
    const m = msg({ payment: 'paid', amountCents: 5500, smsConsent: true })
    expect(m).toContain('They paid $55 online, and it is refunded to their card automatically.')
    expect(m).toContain('a text saying')
  })
  it('says the payment page is closed when it was still waiting for payment', () => {
    expect(msg({ payment: 'pending', amountCents: 5500 })).toContain('payment page is closed')
  })
  it('says nothing about money for a booking paid at the shop', () => {
    expect(msg({ payment: 'shop', amountCents: 5500 })).not.toMatch(/paid|refund|payment/)
  })
})
