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
