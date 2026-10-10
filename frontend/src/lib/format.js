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

// How a phone number is shown to people: (912) 555-0142, however it was typed.
// US numbers (10 digits, or 11 starting with 1) are formatted. Anything else, such as an
// international number, is shown exactly as it was typed.
export function formatPhone(phone) {
  const raw = String(phone ?? '').trim()
  if (/^\+(?!1\b)/.test(raw)) return raw
  const digits = raw.replace(/\D/g, '')
  const ten = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits
  if (ten.length !== 10) return raw
  return `(${ten.slice(0, 3)}) ${ten.slice(3, 6)}-${ten.slice(6)}`
}

// A link that opens the email app, addressed to `email`, with a subject filled in.
// Returns '' when it does not look like an email address, so callers can show plain text instead.
export function mailtoHref(email, subject = '') {
  const address = String(email ?? '').trim()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address)) return ''
  const safe = address.replace(/[?&#%]/g, (c) => encodeURIComponent(c))
  return subject ? `mailto:${safe}?subject=${encodeURIComponent(subject)}` : `mailto:${safe}`
}

// "37/500". Shown under the notes box and updated on every keystroke.
export const countLabel = (used, max) => `${used}/${max}`

// True once 90% of the limit is used, so the counter can warn before the box stops accepting text.
export const nearLimit = (used, max) => used >= Math.floor(max * 0.9)
