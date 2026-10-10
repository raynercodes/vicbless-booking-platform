import { describe, it, expect } from 'vitest'
import { copyrightLine, countLabel, formatPhone, mailtoHref, nearLimit, priceLabel, serviceIdFromHash, telHref } from './format.js'

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

describe('telHref', () => {
  it('turns a US number written any common way into a dialer link', () => {
    expect(telHref('(912) 555-0199')).toBe('tel:+19125550199')
    expect(telHref('912-555-0199')).toBe('tel:+19125550199')
    expect(telHref('912.555.0199')).toBe('tel:+19125550199')
    expect(telHref('9125550199')).toBe('tel:+19125550199')
    expect(telHref(' (912) 555 0199 ')).toBe('tel:+19125550199')
  })

  it('handles a leading 1 and international numbers', () => {
    expect(telHref('1 (912) 555-0199')).toBe('tel:+19125550199')
    expect(telHref('+1 912 555 0199')).toBe('tel:+19125550199')
    expect(telHref('+44 20 7946 0958')).toBe('tel:+442079460958')
  })

  it('falls back to the plain digits for other lengths', () => {
    expect(telHref('555-0199')).toBe('tel:5550199')
  })

  it('returns an empty string when there is nothing to dial', () => {
    expect(telHref('')).toBe('')
    expect(telHref(null)).toBe('')
    expect(telHref(undefined)).toBe('')
    expect(telHref('call us')).toBe('')
  })
})

describe('formatPhone', () => {
  it('shows a US number the same way however it was typed', () => {
    for (const typed of ['9125550142', '912-555-0142', '912.555.0142', '(912) 555-0142', ' 912 555 0142 ', '1 912 555 0142', '+1 912 555 0142', '1-912-555-0142']) {
      expect(formatPhone(typed), typed).toBe('(912) 555-0142')
    }
  })

  it('leaves anything that is not a US number exactly as typed', () => {
    expect(formatPhone('+44 20 7946 0958')).toBe('+44 20 7946 0958')
    expect(formatPhone('555-0142')).toBe('555-0142')
    expect(formatPhone('ask for Vic')).toBe('ask for Vic')
  })

  it('handles empty values', () => {
    expect(formatPhone('')).toBe('')
    expect(formatPhone(null)).toBe('')
    expect(formatPhone(undefined)).toBe('')
  })

  it('pairs with telHref: the displayed number and the dialled number are the same number', () => {
    for (const typed of ['9125550142', '(912) 555-0142', '1 912 555 0142']) {
      expect(telHref(typed)).toBe('tel:+19125550142')
    }
  })
})

describe('mailtoHref', () => {
  it('makes a link that opens the email app', () => {
    expect(mailtoHref('marcus@example.com')).toBe('mailto:marcus@example.com')
  })

  it('fills in the subject, safely encoded', () => {
    expect(mailtoHref('a@b.com', 'Your Vicbless appointment on Thursday, October 8 at 4:15 pm')).toBe(
      'mailto:a@b.com?subject=Your%20Vicbless%20appointment%20on%20Thursday%2C%20October%208%20at%204%3A15%20pm',
    )
    expect(mailtoHref('a@b.com', 'Cuts & fades? #1')).toBe('mailto:a@b.com?subject=Cuts%20%26%20fades%3F%20%231')
  })

  it('trims spaces around the address and keeps plus-addresses intact', () => {
    expect(mailtoHref('  marcus+cuts@example.com  ')).toBe('mailto:marcus+cuts@example.com')
  })

  it('cannot be tricked into adding extra mail headers through the address', () => {
    // a second @ or a real line break: the address is refused outright
    expect(mailtoHref('a@b.com?bcc=evil@x.com')).toBe('')
    expect(mailtoHref('a@b.com&cc=evil@x.com')).toBe('')
    expect(mailtoHref('a@b.com\nBcc: evil@x.com')).toBe('')
    // otherwise ? & and % are encoded, so they stay part of the address and start no new header
    expect(mailtoHref('a@b.com?bcc=evil')).toBe('mailto:a@b.com%3Fbcc=evil')
    expect(mailtoHref('a@b.com&cc=evil')).toBe('mailto:a@b.com%26cc=evil')
    expect(mailtoHref('a@b.com%0d%0aBcc:x')).toBe('mailto:a@b.com%250d%250aBcc:x')
  })

  it('returns nothing for things that are not an email address, so plain text is shown instead', () => {
    for (const bad of ['', '   ', 'marcus', 'marcus@', '@example.com', 'a@b', 'a b@c.com', 'a@b .com', null, undefined, 42]) {
      expect(mailtoHref(bad), String(bad)).toBe('')
    }
  })
})

describe('countLabel', () => {
  it('shows used over the limit', () => {
    expect(countLabel(0, 500)).toBe('0/500')
    expect(countLabel(37, 500)).toBe('37/500')
    expect(countLabel(500, 500)).toBe('500/500')
  })
})

describe('nearLimit', () => {
  it('turns on at 90% of the limit and stays on', () => {
    expect(nearLimit(0, 500)).toBe(false)
    expect(nearLimit(449, 500)).toBe(false)
    expect(nearLimit(450, 500)).toBe(true)
    expect(nearLimit(500, 500)).toBe(true)
  })
})
