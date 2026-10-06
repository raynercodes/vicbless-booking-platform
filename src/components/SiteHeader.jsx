import Logo from './Logo.jsx'
import Socials from './Socials.jsx'

// Stays pinned to the top while the page scrolls (see .brand in styles.css).
// The logo scrolls back to the top of the page.
function goToTop(e) {
  e.preventDefault()
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  window.scrollTo({ top: 0, behavior: reduce ? 'auto' : 'smooth' })
}

export default function SiteHeader() {
  return (
    <header className="brand">
      <Logo onClick={goToTop} />
      <Socials />
    </header>
  )
}
