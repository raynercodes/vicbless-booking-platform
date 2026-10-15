import { LOGO_PATH, LOGO_VIEWBOX } from './logoPath.js'

// A faint checkerboard of the Vicbless logo for the background of the booking success screen: the logo sits in
// every other square, so each row is shifted half a tile from the one above it. It is only decoration.
const TILE_W = 240
const TILE_H = 100

export default function LogoCheckerboard() {
  const logo = (x, y) => (
    <svg x={x + 20} y={y + 18} width={TILE_W - 40} height={TILE_H - 36} viewBox={LOGO_VIEWBOX}>
      <path d={LOGO_PATH} />
    </svg>
  )
  return (
    <div className="logo-checker" aria-hidden="true">
      <svg width="100%" height="100%" focusable="false">
        <defs>
          <pattern id="logo-checker-tile" width={TILE_W * 2} height={TILE_H * 2} patternUnits="userSpaceOnUse">
            {logo(0, 0)}
            {logo(TILE_W, TILE_H)}
          </pattern>
        </defs>
        <rect width="100%" height="100%" fill="url(#logo-checker-tile)" />
      </svg>
    </div>
  )
}
