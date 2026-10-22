// Errors shared by the mock and the real data layer, so the pages can catch one kind of error
// whichever layer is behind them.

// The time a customer picked is no longer free (somebody got there first, or it has passed).
// Book.jsx catches this one: it sends the customer back to the time grid with fresh availability.
export class SlotTakenError extends Error {
  constructor(message = 'That time was just taken.') {
    super(message)
    this.name = 'SlotTakenError'
  }
}

// Backend error codes whose message was written to be read by a person, so the pages show it as it is.
// (Anything else, like a 500, gets the pages' own generic wording instead of a technical message.)
const FRIENDLY = new Set(['validation_error', 'invalid_slot', 'too_many_bookings', 'too_many_attempts', 'unauthorized', 'payment_unavailable', 'refund_failed'])

// Anything the real API (or the network on the way to it) answers with an error.
//   status   HTTP status, or 0 when the server could not be reached at all
//   apiCode  the backend's word for it: 'slot_taken', 'conflict', 'validation_error', 'network', ...
//   code     same as apiCode, except the admin screens use the older 'CONFLICT' / 'INVALID' words
//            (see realAdminApi.js), so that is the one they branch on
//   field    which input the message is about, when the backend says (validation errors)
//   friendly true when `message` is safe and useful to show as it is
export class ApiError extends Error {
  constructor({ status, code, message, field }) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.apiCode = code
    this.code = code
    this.field = field || ''
    this.friendly = FRIENDLY.has(code)
  }
}
