import { LOGO_PATH, LOGO_VIEWBOX } from './logoPath.js'

// The Vicbless wordmark.
//   onClick  makes it a link back to the top of the page (used in the public site's header). That one also
//            does the coin spin (see "Logo coin spin" at the end of styles.css): it stands still for a couple of
//            seconds, spins like a coin, and stands straight again. Both faces are the same logo, so the
//            writing never reads backwards.
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

  // The coin: a front face, and a back face turned around behind it (hidden until the coin is turned).
  // The back one is only for looks, so screen readers skip it.
  const coin = (
    <span className="logo-coin">
      <span className="logo-face">{art}</span>
      <span className="logo-face logo-face-back" aria-hidden="true">
        {art}
      </span>
    </span>
  )

  return (
    <h1 className="logo">
      {onClick ? (
        <a className="logo-link" href="/" onClick={onClick}>
          {coin}
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
