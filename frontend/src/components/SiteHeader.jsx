import Logo from './Logo.jsx'
import SiteMenu from './SiteMenu.jsx'
import Socials from './Socials.jsx'
import { getSettings } from '../lib/useSettings.js'

// Stays pinned to the top while the page scrolls (see .brand in styles.css).
// Menu on the left, logo in the middle, social links on the right.
// The logo scrolls back to the top of the page (jumps instead of gliding when motion is off).
function goToTop(e) {
  e.preventDefault()
  window.scrollTo({ top: 0, behavior: getSettings().motion === 'off' ? 'auto' : 'smooth' })
}

export default function SiteHeader() {
  return (
    <header className="brand">
      <SiteMenu />
      <Logo onClick={goToTop} />
      <Socials />
    </header>
  )
}
