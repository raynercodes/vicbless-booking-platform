import { LOGO_PATH, LOGO_VIEWBOX } from './logoPath.js'

// The Vicbless wordmark.
//   onClick  makes it a link back to the top of the page (used in the public site's header)
//   as       'h1' (default) makes it the page heading. Anything else makes it a plain picture,
//            for screens that have their own heading (Vic's dashboard).
export default function Logo({ onClick, as = 'h1' }) {
  const art = (
    <svg viewBox={LOGO_VIEWBOX} aria-hidden="true" focusable="false">
      <path d={LOGO_PATH} />
    </svg>
  )

  if (as !== 'h1') {
    return (
      <div className="logo" role="img" aria-label="Vicbless Barbershop">
        {art}
      </div>
    )
  }

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
