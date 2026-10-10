import Logo from '../components/Logo.jsx'
import { useSettings } from '../lib/useSettings.js'

// The normal Vicbless logo (the very same component, so the letters are exactly as before) going around
// an oval like a carousel (an "orbit"), and turning as it goes: it faces you at the front of the oval,
// turns edge-on at the sides, and faces away at the back, where the writing reads backwards, like a mirror.
// It is bigger at the front and smaller at the back. One full turn for each lap, and it stays flat.
//   variant="hero"  the one on the sign-in screen
//   variant="bar"   the one in the dashboard's top bar (its frame is the whole width of the bar)
// With Motion off in the menu it stops and just sits in its place, facing front.
// The speed, the size of the oval and the depth are variables at the top of the "logo" section in admin.css.
export default function LoopingLogo({ variant = 'hero' }) {
  const { motion } = useSettings()

  return (
    <div className={`admin-loop admin-loop-${variant}`}>
      <div className="admin-loop-frame">
        <div className={motion === 'off' ? 'admin-loop-orbit admin-loop-still' : 'admin-loop-orbit'}>
          <Logo as="div" />
        </div>
      </div>
    </div>
  )
}
