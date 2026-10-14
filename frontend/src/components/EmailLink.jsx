import { BUSINESS } from '../config.js'
import { mailtoHref } from '../lib/format.js'

// The shop's contact email as a tap-to-write link. Use this anywhere customers are told how to reach Vic,
// so the address only ever has to be changed in config.js. (It keeps the "phone-link" style name so it looks
// like the other links on the site.)
export default function EmailLink() {
  return (
    <a className="phone-link" href={mailtoHref(BUSINESS.email)}>
      {BUSINESS.email}
    </a>
  )
}
