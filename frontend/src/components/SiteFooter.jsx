import Socials from './Socials.jsx'
import { CREDIT } from '../config.js'
import { copyrightLine } from '../lib/format.js'

export default function SiteFooter() {
  return (
    <footer className="site-foot">
      <Socials />
      <p className="copy">{copyrightLine()}</p>
      <p className="credit">
        <a href={CREDIT.url} target="_blank" rel="noopener">
          {CREDIT.text}
          <span className="sr-only"> (opens in a new tab)</span>
        </a>
      </p>
    </footer>
  )
}
