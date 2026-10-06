// Small shared display helpers.

// price is the starting price. from: true shows it as "$65+".
export const priceLabel = (s) => (s.from ? `$${s.price}+` : `$${s.price}`)

// The footer line. Takes a date so the year is always the current one.
export const copyrightLine = (date = new Date()) => `\u00A9 ${date.getFullYear()} VICBLESS`

// Reads the service from a link like "#/book?service=mens-design".
// Returns null when there is no service or it is not a real one.
export function serviceIdFromHash(hash, services) {
  const query = (hash || '').split('?')[1] || ''
  const id = new URLSearchParams(query).get('service')
  return services.some((s) => s.id === id) ? id : null
}

// Turns a phone number as people write it, like "(912) 555-0199", into a link that opens the
// phone's dialer: "tel:+19125550199". A 10-digit number is treated as a US number.
// Returns '' when there are no digits, so callers can fall back to plain text.
export function telHref(phone) {
  const raw = String(phone ?? '').trim()
  const digits = raw.replace(/\D/g, '')
  if (!digits) return ''
  if (raw.startsWith('+')) return `tel:+${digits}`
  if (digits.length === 10) return `tel:+1${digits}`
  if (digits.length === 11 && digits.startsWith('1')) return `tel:+${digits}`
  return `tel:${digits}`
}
