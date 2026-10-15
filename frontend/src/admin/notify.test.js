import { describe, it, expect } from 'vitest'
import { cancelMessage, textsLabel, whoIsTold } from './notify'

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
    expect(textsLabel({ smsConsent: true })).toEqual({ mark: '✓', words: 'Texts OK', on: true })
    expect(textsLabel({})).toEqual({ mark: '✗', words: 'No texts', on: false })
  })
})
