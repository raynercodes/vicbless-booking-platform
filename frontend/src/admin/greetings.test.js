import { describe, it, expect } from 'vitest'
import { GREETINGS, pickGreeting, splitName } from './greetings.js'

describe('the greeting list', () => {
  it('has the four messages Vic asked for, worded exactly', () => {
    for (const wanted of ['Welcome Back, Victor', 'Slicing it up today, Vic', "Let's Bless the day, Vic", 'Professor Vic, Welcome']) {
      expect(GREETINGS).toContain(wanted)
    }
  })

  it('has no duplicates and nothing blank', () => {
    expect(new Set(GREETINGS).size).toBe(GREETINGS.length)
    for (const g of GREETINGS) expect(g.trim().length).toBeGreaterThan(3)
  })

  it('every message greets him by name', () => {
    for (const g of GREETINGS) expect(g).toMatch(/\b(Vic|Victor)\b/)
  })
})

describe('pickGreeting', () => {
  it('can reach every message', () => {
    const seen = new Set()
    for (let i = 0; i < GREETINGS.length; i++) seen.add(pickGreeting({ random: () => (i + 0.5) / GREETINGS.length }))
    expect(seen.size).toBe(GREETINGS.length)
  })

  it('never returns the one it was told was last, however the dice fall', () => {
    for (const last of GREETINGS) {
      for (let step = 0; step <= 100; step++) {
        expect(pickGreeting({ random: () => step / 100, last })).not.toBe(last)
      }
    }
  })

  it('handles the extremes of the random number (0 and just under 1)', () => {
    expect(GREETINGS).toContain(pickGreeting({ random: () => 0 }))
    expect(GREETINGS).toContain(pickGreeting({ random: () => 0.9999999 }))
    expect(GREETINGS).toContain(pickGreeting({ random: () => 1 })) // out of range on purpose: must not return undefined
  })

  it('works with a list of one (nothing else to choose, so it repeats rather than failing)', () => {
    expect(pickGreeting({ list: ['Only one, Vic'], last: 'Only one, Vic' })).toBe('Only one, Vic')
  })

  it('treats an unknown or empty "last" as no restriction', () => {
    expect(GREETINGS).toContain(pickGreeting({ last: 'something that was removed from the list' }))
    expect(GREETINGS).toContain(pickGreeting({ last: '' }))
  })

  it('actually varies when run for real', () => {
    const seen = new Set()
    let last = ''
    for (let i = 0; i < 200; i++) {
      const g = pickGreeting({ last })
      expect(g).not.toBe(last)
      seen.add(g)
      last = g
    }
    expect(seen.size).toBeGreaterThan(5)
  })
})

describe('splitName', () => {
  it('colours Vic and Victor wherever they are in the message', () => {
    expect(splitName('Slicing it up today, Vic')).toEqual([{ text: 'Slicing it up today, ' }, { text: 'Vic', accent: true }])
    expect(splitName('Professor Vic, Welcome')).toEqual([{ text: 'Professor ' }, { text: 'Vic', accent: true }, { text: ', Welcome' }])
    expect(splitName('Welcome Back, Victor')).toEqual([{ text: 'Welcome Back, ' }, { text: 'Victor', accent: true }])
  })

  it('never changes the wording: the pieces join back into the original', () => {
    for (const g of GREETINGS) expect(splitName(g).map((p) => p.text).join('')).toBe(g)
  })

  it('does not colour part of another word', () => {
    expect(splitName('Victory is yours')).toEqual([{ text: 'Victory is yours' }])
  })

  it('a message with no name stays one plain piece', () => {
    expect(splitName('Good morning')).toEqual([{ text: 'Good morning' }])
  })
})
