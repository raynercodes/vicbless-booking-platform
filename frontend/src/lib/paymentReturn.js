// Paying online sends the customer to Stripe and back. This remembers what they were booking while they are away, and
// reads the address Stripe sends them back to:
//   #/book?paid=VB-XXXXXX      they paid: show the "You're booked" screen
//   #/book?payment=cancelled   they came back without paying: put their details back so they can try again
// The memory is the browser tab's own (sessionStorage), and only what the customer typed plus the booking's answer.

export const PENDING_KEY = 'vicbless.pendingPayment'

const CODE = /^VB-[A-Z0-9]{4,12}$/

// What the address says about a trip to Stripe: { kind: 'paid', code } | { kind: 'cancelled' } | null.
export function readReturn(hash) {
  const query = String(hash || '').split('?')[1] || ''
  const params = new URLSearchParams(query)
  const paid = params.get('paid')
  if (paid && CODE.test(paid)) return { kind: 'paid', code: paid }
  if (params.get('payment') === 'cancelled') return { kind: 'cancelled' }
  return null
}

// { request: { serviceId, dateKey, time, form }, booking } is what the booking page saves before leaving for Stripe.
export function savePending(storage, pending) {
  try {
    storage?.setItem(PENDING_KEY, JSON.stringify(pending))
  } catch {
    /* storage blocked: the customer just starts the form again */
  }
}

export function loadPending(storage) {
  try {
    const saved = JSON.parse(storage?.getItem(PENDING_KEY) || 'null')
    if (saved && saved.request && saved.booking && typeof saved.booking.code === 'string') return saved
  } catch {
    /* unreadable: treated as nothing saved */
  }
  return null
}

export function clearPending(storage) {
  try {
    storage?.removeItem(PENDING_KEY)
  } catch {
    /* nothing to clear */
  }
}

// The browser tab's storage, or null when it is blocked.
export function tabStorage() {
  try {
    return window.sessionStorage
  } catch {
    return null
  }
}
