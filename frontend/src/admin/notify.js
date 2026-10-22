// Who is told when Vic cancels a booking: a text if the customer ticked the box, an email if they left one.
// This mirrors the backend, which texts only customers who agreed and emails only those who left an address.

export function whoIsTold(item) {
  return { text: item.smsConsent === true, email: Boolean(item.email && item.email.trim()) }
}

// '$65' or '$65.50' from cents; '' when there is no amount (a booking made before prices were kept).
export function money(cents) {
  if (!Number.isInteger(cents) || cents <= 0) return ''
  const dollars = Math.floor(cents / 100)
  const rest = cents % 100
  return rest ? `$${dollars}.${String(rest).padStart(2, '0')}` : `$${dollars}`
}

export function cancelMessage(item, timeLabel, serviceName) {
  const { text, email } = whoIsTold(item)
  const head = `Cancel ${item.name}'s ${timeLabel} ${serviceName}? The time opens up for other customers.`
  let told
  if (text && email) told = 'They are sent a text and an email saying it was cancelled.'
  else if (text) told = 'They are sent a text saying it was cancelled.'
  else if (email) told = 'They are sent an email saying it was cancelled.'
  else told = "They won't be told, because they didn't agree to texts or leave an email."
  let money_ = ''
  if (item.payment === 'paid') {
    const amount = money(item.amountCents)
    money_ = ` They paid${amount ? ` ${amount}` : ''} online, and it is refunded to their card automatically.`
  } else if (item.payment === 'pending') {
    money_ = ' They had not paid yet, so their payment page is closed.'
  }
  return `${head} ${told}${money_}`
}

// How the customer is paying, for the badge on the card: paid online, still to pay online, or paying at the shop.
export function paymentLabel(item) {
  const amount = money(item.amountCents)
  const tail = amount ? ` · ${amount}` : ''
  if (item.payment === 'paid') return { state: 'paid', mark: '✓', words: `Paid online${tail}` }
  if (item.payment === 'pending') return { state: 'pending', mark: '…', words: `Waiting for payment${tail}` }
  return { state: 'shop', mark: '$', words: `Pay at the shop${tail}` }
}

// The short label beside the phone number. The mark and the words both say it, so colour is never the only clue.
export function textsLabel(item) {
  return item.smsConsent === true ? { mark: '✓', words: 'Text Reminders', on: true } : { mark: '✗', words: 'No Text Reminders', on: false }
}
