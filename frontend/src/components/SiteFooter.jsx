import Socials from './Socials.jsx'
import { copyrightLine } from '../lib/format.js'

export default function SiteFooter() {
  return (
    <footer className="site-foot">
      <Socials />
      <p className="copy">{copyrightLine()}</p>
    </footer>
  )
}
