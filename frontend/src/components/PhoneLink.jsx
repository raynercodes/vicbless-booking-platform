import { BUSINESS } from '../config.js'
import { telHref } from '../lib/format.js'

// The shop's phone number as a tap-to-call link. Use this anywhere the number is shown,
// so it only ever has to be changed in config.js.
export default function PhoneLink() {
  const href = telHref(BUSINESS.phone)
  if (!href) return <>{BUSINESS.phone}</>
  return (
    <a className="phone-link" href={href}>
      {BUSINESS.phone}
    </a>
  )
}
