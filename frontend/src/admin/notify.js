// Who is told when Vic cancels a booking: a text if the customer ticked the box, an email if they left one.
// This mirrors the backend, which texts only customers who agreed and emails only those who left an address.

export function whoIsTold(item) {
  return { text: item.smsConsent === true, email: Boolean(item.email && item.email.trim()) }
}

export function cancelMessage(item, timeLabel, serviceName) {
  const { text, email } = whoIsTold(item)
  const head = `Cancel ${item.name}'s ${timeLabel} ${serviceName}? The time opens up for other customers.`
  if (text && email) return `${head} They are sent a text and an email saying it was cancelled.`
  if (text) return `${head} They are sent a text saying it was cancelled.`
  if (email) return `${head} They are sent an email saying it was cancelled.`
  return `${head} They won't be told, because they didn't agree to texts or leave an email.`
}

// The short label beside the phone number. The mark and the words both say it, so colour is never the only clue.
export function textsLabel(item) {
  return item.smsConsent === true ? { mark: '✓', words: 'Texts OK', on: true } : { mark: '✗', words: 'No texts', on: false }
}
