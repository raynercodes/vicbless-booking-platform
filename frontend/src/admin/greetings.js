// The messages Vic is greeted with when he opens his dashboard.
// A new one each visit, never the same one twice in a row. Add, remove or reword freely.
// Any "Vic" or "Victor" in a message is shown in the purple accent colour.
export const GREETINGS = [
  // from Vic
  'Welcome Back, Victor',
  'Slicing it up today, Vic',
  "Let's Bless the day, Vic",
  'Professor Vic, Welcome',
  // more in the same spirit (change or delete any of these)
  'Fresh day, fresh cuts, Vic',
  'The chair is ready, Vic',
  'Another blessing of a day, Vic',
  "Let's get it, Vic",
  'Sharp day ahead, Vic',
  'The shop is yours, Vic',
]

// Picks a message at random, skipping `last` so it never repeats back to back.
// `random` is injectable so this can be tested.
export function pickGreeting({ random = Math.random, last = '', list = GREETINGS } = {}) {
  const options = list.filter((message) => message !== last)
  const pool = options.length > 0 ? options : list
  return pool[Math.min(pool.length - 1, Math.floor(random() * pool.length))]
}

// Splits a message into pieces so the name can be coloured:
// "Slicing it up today, Vic" -> [{ text: 'Slicing it up today, ' }, { text: 'Vic', accent: true }]
export function splitName(message) {
  return String(message)
    .split(/\b(Victor|Vic)\b/)
    .filter((text) => text !== '')
    .map((text) => (text === 'Vic' || text === 'Victor' ? { text, accent: true } : { text }))
}
