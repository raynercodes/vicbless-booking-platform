import { LOGO_PATH, LOGO_VIEWBOX } from './logoPath.js'

// Pass onClick to make the logo a link back to the top of the page.
export default function Logo({ onClick }) {
  const art = (
    <svg viewBox={LOGO_VIEWBOX} aria-hidden="true" focusable="false">
      <path d={LOGO_PATH} />
    </svg>
  )

  return (
    <h1 className="logo">
      {onClick ? (
        <a className="logo-link" href="/" onClick={onClick}>
          {art}
          <span className="sr-only">Vicbless Barbershop, back to top</span>
        </a>
      ) : (
        <>
          {art}
          <span className="sr-only">Vicbless Barbershop</span>
        </>
      )}
    </h1>
  )
}
