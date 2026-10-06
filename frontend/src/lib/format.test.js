import { describe, it, expect } from 'vitest'
import { priceLabel, copyrightLine, serviceIdFromHash } from './format.js'

describe('priceLabel', () => {
  it('shows a plus for starting prices', () => {
    expect(priceLabel({ price: 65, from: true })).toBe('$65+')
    expect(priceLabel({ price: 55 })).toBe('$55')
  })
})

describe('copyrightLine', () => {
  it('uses the year of the date it is given', () => {
    expect(copyrightLine(new Date(2026, 5, 1))).toBe('\u00A9 2026 VICBLESS')
    expect(copyrightLine(new Date(2031, 0, 1))).toBe('\u00A9 2031 VICBLESS')
  })

  it('defaults to the current year', () => {
    expect(copyrightLine()).toBe(`\u00A9 ${new Date().getFullYear()} VICBLESS`)
  })

  it('rolls over at midnight on New Year', () => {
    expect(copyrightLine(new Date(2026, 11, 31, 23, 59))).toContain('2026')
    expect(copyrightLine(new Date(2027, 0, 1, 0, 0))).toContain('2027')
  })
})

describe('serviceIdFromHash', () => {
  const services = [{ id: 'mens-cut' }, { id: 'mens-design' }]

  it('reads a real service from the link', () => {
    expect(serviceIdFromHash('#/book?service=mens-design', services)).toBe('mens-design')
  })

  it('returns null with no service, an unknown service, or an empty hash', () => {
    expect(serviceIdFromHash('#/book', services)).toBeNull()
    expect(serviceIdFromHash('#/book?service=nope', services)).toBeNull()
    expect(serviceIdFromHash('', services)).toBeNull()
    expect(serviceIdFromHash(undefined, services)).toBeNull()
  })
})
