// Keeps the search-engine data in index.html honest: the structured data Google reads about the shop must say the
// same thing as config.js (address, hours, social links), so changing one without the other fails here.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { BUSINESS, HOURS, SOCIAL } from '../config.js'

const html = readFileSync(new URL('../../index.html', import.meta.url), 'utf8')
const jsonLd = () => {
  const match = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)
  expect(match, 'index.html has no application/ld+json block').toBeTruthy()
  return JSON.parse(match[1])
}

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const hhmm = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`

describe('structured data (JSON-LD)', () => {
  it('describes a barber shop with the name and the address from config.js', () => {
    const data = jsonLd()
    expect(data['@type']).toBe('BarberShop')
    expect(data.name).toBe(BUSINESS.name)
    const [street, cityLine] = BUSINESS.address
    const [city, rest] = cityLine.split(', ')
    const [region, zip] = rest.split(' ')
    expect(data.address).toMatchObject({ '@type': 'PostalAddress', streetAddress: street, addressLocality: city, addressRegion: region, postalCode: zip, addressCountry: 'US' })
  })

  it('lists exactly the opening hours in config.js', () => {
    const expected = []
    for (const [day, windows] of Object.entries(HOURS)) {
      for (const [open, close] of windows || []) expected.push(`${DAY_NAMES[day]} ${hhmm(open)}-${hhmm(close)}`)
    }
    const listed = []
    for (const spec of jsonLd().openingHoursSpecification) {
      for (const day of [].concat(spec.dayOfWeek)) listed.push(`${day} ${spec.opens}-${spec.closes}`)
    }
    expect(listed.sort()).toEqual(expected.sort())
  })

  it('links the social profiles from config.js', () => {
    expect([...jsonLd().sameAs].sort()).toEqual(Object.values(SOCIAL).sort())
  })

  it('does not publish the placeholder phone number', () => {
    // BUSINESS.phone is still a placeholder. Add "telephone" to the JSON-LD only once it is Vic's real number.
    if (/PLACEHOLDER|\(555\)/.test(BUSINESS.phone)) expect(jsonLd()).not.toHaveProperty('telephone')
  })
})

describe('page head', () => {
  it('has one title, a description, a canonical address, and allows indexing', () => {
    expect(html.match(/<title>/g)).toHaveLength(1)
    expect(html).toMatch(/<meta name="description" content="[^"]{50,170}"/)
    expect(html).toContain('<link rel="canonical" href="https://vicbless.com/" />')
    expect(html).toMatch(/<meta name="robots" content="index, follow/)
  })
})
