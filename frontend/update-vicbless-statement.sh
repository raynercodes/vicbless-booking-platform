#!/usr/bin/env bash
# Vicbless: photo section under the video (parallax photo, headline, paragraph, stacked words).
# Run from inside frontend/:  bash update-vicbless-statement.sh
# First put vicbless-cutting-hair.jpg into public/media/ (it is attached next to this script).
# Replaces these files with full new versions. If you edited any of them locally, tell me first.
set -euo pipefail

if [ ! -f package.json ] || ! grep -q vicbless-booking-platform package.json || [ ! -f src/components/Reveal.jsx ]; then
  echo "Run this from inside the frontend/ folder (with the earlier updates applied)."
  exit 1
fi

mkdir -p public/media src/components src/pages

cat > src/config.js <<'VICBLESS_EOF'
// Everything business-specific lives here.
// Hours, services, address and social links are Vic's real ones. The phone number is still a PLACEHOLDER.

export const BUSINESS = {
  name: 'Vicbless Barbershop',
  phone: '(555) 010-0123', // PLACEHOLDER
  address: ['656 S Main St, Suite C', 'Baxley, GA 31513'],
}

export const SOCIAL = {
  tiktok: 'https://www.tiktok.com/@vicblesss',
  instagram: 'https://www.instagram.com/vicblessss',
}

// Vic is the only staff for now. Add more entries later and the booking
// payload already carries a staffId, so the data model will not change.
export const STAFF = [{ id: 'vic', name: 'Vic' }]

// Opening windows per weekday, in minutes after midnight. 0 = Sunday.
// null = closed. A day can have several windows (Saturday has a break).
const at = (h, m = 0) => h * 60 + m

export const HOURS = {
  0: null, // Sunday: closed
  1: [[at(12), at(18)]], // Monday 12:00 pm to 6:00 pm
  2: [[at(12), at(18)]], // Tuesday 12:00 pm to 6:00 pm
  3: null, // Wednesday: closed
  4: [[at(11), at(19)]], // Thursday 11:00 am to 7:00 pm
  5: [[at(11), at(19)]], // Friday 11:00 am to 7:00 pm
  6: [
    [at(9), at(12)], // Saturday 9:00 am to 12:00 pm
    [at(12, 35), at(17)], // and 12:35 pm to 5:00 pm
  ],
}

// price is the starting price. from: true shows it as "$65+".
export const SERVICES = [
  { id: 'mens-cut', name: "Men's haircut", minutes: 35, price: 55 },
  {
    id: 'mens-design',
    name: "Men's haircut with design",
    minutes: 35,
    price: 65,
    from: true,
    note: 'Small or freestyle design',
  },
  {
    id: 'mens-beard-eyebrow',
    name: "Men's haircut with beard and eyebrow",
    minutes: 35,
    price: 65,
    from: true,
    note: 'Includes free hot towel if requested and hair styling',
  },
  {
    id: 'buzz-beard',
    name: 'Head buzzed/shave and beard',
    minutes: 30,
    price: 40,
    note: 'Same price for just beards. Tell Vic in person if you want it buzzed or shaved.',
  },
  {
    id: 'kids-design',
    name: 'Kids cut (12 and under) with design',
    minutes: 30,
    price: 40,
    from: true,
    note: '$5 extra for a small design, $10 more for a bigger design',
  },
]

// Vic books in 35 minute blocks (Saturday's 12:35 restart follows the same rhythm).
// Every service fits in one block, longer ones would take several.
export const SLOT_MINUTES = 35
export const DAYS_AHEAD = 14

// The branded call to action. Used on every booking button.
export const CTA_TEXT = 'Book here to get blessed'

// The photo section under the video: headline, paragraph, and the words stacked over the photo.
export const STATEMENT = {
  headline: "EVERY CUT ISN'T JUST A CUT. IT'S A BLESSING.",
  body: 'Consistent precision cuts with clean detail and a personalized cut experience to give you confidence and blessings.',
  words: ['Quality', 'Detail', 'Consistency', 'Baxley, GA'],
}
VICBLESS_EOF

cat > src/components/Reveal.jsx <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'

// Fades and moves its content in once it scrolls into view.
//   from="below" (default) lifts up into place, from="above" drops down into place.
// Shows immediately when the browser has no IntersectionObserver or the visitor
// prefers reduced motion, so nothing is ever left hidden.
export default function Reveal({ as: Tag = 'div', from = 'below', delay = 0, className = '', children, ...rest }) {
  const ref = useRef(null)
  const [shown, setShown] = useState(
    () =>
      typeof window === 'undefined' ||
      !('IntersectionObserver' in window) ||
      window.matchMedia('(prefers-reduced-motion: reduce)').matches,
  )

  useEffect(() => {
    if (shown) return undefined
    const el = ref.current
    if (!el) return undefined
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setShown(true)
          io.disconnect()
        }
      },
      { threshold: 0.15, rootMargin: '0px 0px -8% 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [shown])

  const classes = ['reveal', from === 'above' ? 'reveal-down' : '', shown ? 'in' : '', className]
    .filter(Boolean)
    .join(' ')

  return (
    <Tag ref={ref} className={classes} style={{ '--d': `${delay}ms` }} {...rest}>
      {children}
    </Tag>
  )
}
VICBLESS_EOF

cat > src/components/Statement.jsx <<'VICBLESS_EOF'
import { useEffect, useRef } from 'react'
import Reveal from './Reveal.jsx'
import { STATEMENT } from '../config.js'

// Photo section with its own parallax. --pan goes 0 to 1 as the section travels from
// entering the bottom of the screen to leaving the top, and slides the (taller) photo
// through the section. Skipped for reduced motion, which leaves the photo centred.
export default function Statement() {
  const ref = useRef(null)

  useEffect(() => {
    const el = ref.current
    if (!el || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return undefined

    let frame = 0
    const update = () => {
      frame = 0
      const rect = el.getBoundingClientRect()
      const vh = window.innerHeight
      const p = Math.min(1, Math.max(0, (vh - rect.top) / (vh + rect.height)))
      el.style.setProperty('--pan', p.toFixed(3))
    }
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update)
    }

    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (frame) window.cancelAnimationFrame(frame)
      el.style.removeProperty('--pan')
    }
  }, [])

  const last = STATEMENT.words.length - 1

  return (
    <section ref={ref} className="statement" aria-labelledby="statement-title">
      <img
        className="statement-img"
        src="/media/vicbless-cutting-hair.jpg"
        alt="A barber trimming a customer's hair at Vicbless Barbershop"
        loading="lazy"
        decoding="async"
      />

      <div className="statement-inner">
        <div className="statement-top">
          <Reveal as="h2" id="statement-title">
            {STATEMENT.headline}
          </Reveal>
          <Reveal as="p" delay={120}>
            {STATEMENT.body}
          </Reveal>
        </div>

        <ul className="statement-words">
          {STATEMENT.words.map((word, i) => (
            <Reveal as="li" from="above" delay={i * 180} key={word} className={i === last ? 'statement-place' : ''}>
              {word}
            </Reveal>
          ))}
        </ul>
      </div>
    </section>
  )
}
VICBLESS_EOF

cat > src/pages/Home.jsx <<'VICBLESS_EOF'
import { useEffect, useRef, useState } from 'react'
import SiteHeader from '../components/SiteHeader.jsx'
import SiteFooter from '../components/SiteFooter.jsx'
import ShopInfo from '../components/ShopInfo.jsx'
import Statement from '../components/Statement.jsx'
import Socials from '../components/Socials.jsx'
import { CTA_TEXT } from '../config.js'

function usePrefersReducedMotion() {
  const [reduce, setReduce] = useState(
    () => typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches,
  )
  useEffect(() => {
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)')
    const onChange = () => setReduce(mq.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])
  return reduce
}

const PlayIcon = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M8 5v14l11-7z" fill="currentColor" />
  </svg>
)

const PauseIcon = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor" />
  </svg>
)

// The pan finishes after the visitor has scrolled 85% of the video's height,
// so the movement reads as stronger and faster.
const PAN_DISTANCE = 0.85

export default function Home() {
  const reduceMotion = usePrefersReducedMotion()
  const heroRef = useRef(null)
  const videoRef = useRef(null)
  const [playing, setPlaying] = useState(false)

  // Keep the button in step with the real video state (autoplay can be blocked).
  useEffect(() => {
    const v = videoRef.current
    if (!v) return undefined
    const sync = () => setPlaying(!v.paused)
    v.addEventListener('play', sync)
    v.addEventListener('pause', sync)
    sync()
    return () => {
      v.removeEventListener('play', sync)
      v.removeEventListener('pause', sync)
    }
  }, [])

  // Autoplay, including on iPhone. React does not write the muted attribute that iOS
  // wants before it will autoplay, so set it on the element and call play() ourselves.
  // If the phone still blocks it (Low Power Mode, for example), the first touch or
  // scroll starts it. The pause/play button is left alone so it never fights itself.
  useEffect(() => {
    const v = videoRef.current
    if (!v) return undefined
    v.muted = true
    v.defaultMuted = true
    v.setAttribute('muted', '')

    const events = ['touchstart', 'pointerdown', 'scroll', 'keydown']
    const stopWaiting = () => events.forEach((name) => window.removeEventListener(name, onGesture))
    const attempt = () => {
      const result = v.play()
      if (result && typeof result.then === 'function') result.then(stopWaiting).catch(() => {})
      else stopWaiting()
    }
    function onGesture(e) {
      if (e.target instanceof Element && e.target.closest('.hero-toggle')) return
      attempt()
    }

    events.forEach((name) => window.addEventListener(name, onGesture, { passive: true }))
    attempt()
    return stopWaiting
  }, [])

  // Pan: as the page scrolls, the footage slides from its top to its bottom
  // (--pan goes 0 to 1 over the first 85% of the hero's height of scrolling). Skipped for reduced motion.
  useEffect(() => {
    if (reduceMotion) return undefined
    const hero = heroRef.current
    if (!hero) return undefined
    let frame = 0
    const update = () => {
      frame = 0
      const h = hero.offsetHeight || 1
      const p = Math.min(1, Math.max(0, window.scrollY / (h * PAN_DISTANCE)))
      hero.style.setProperty('--pan', p.toFixed(3))
    }
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update)
    }
    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (frame) window.cancelAnimationFrame(frame)
      hero.style.removeProperty('--pan')
    }
  }, [reduceMotion])

  function toggle() {
    const v = videoRef.current
    if (!v) return
    if (v.paused) v.play().catch(() => {})
    else v.pause()
  }

  return (
    <>
      <SiteHeader />

      <main>
        <section ref={heroRef} className="hero" aria-label="Vicbless presentation">
          <img className="hero-backdrop" src="/media/vicbless-poster.jpg" alt="" aria-hidden="true" />
          <video
            ref={videoRef}
            className="hero-video"
            src="/media/vicbless-presentation.mp4"
            poster="/media/vicbless-poster.jpg"
            muted
            loop
            playsInline
            preload="auto"
            autoPlay
            aria-label="Vicbless presentation video"
          />

          <div className="hero-cta">
            <a className="btn btn-primary book-now" href="#/book">
              {CTA_TEXT}
            </a>
          </div>

          <div className="hero-socials">
            <Socials />
          </div>

          <button
            type="button"
            className="hero-toggle"
            onClick={toggle}
            aria-label={playing ? 'Pause video' : 'Play video'}
          >
            {playing ? <PauseIcon /> : <PlayIcon />}
          </button>
        </section>

        <Statement />

        <ShopInfo />
      </main>

      <SiteFooter />
    </>
  )
}
VICBLESS_EOF

cat > src/styles.css <<'VICBLESS_EOF'
/* Vicbless: dark purple-black ground, light lavender ink, small purple accents. */
:root {
  --bg: #0a0612;
  --surface: #130c21;
  --ink: #f6efff;
  --muted: #b3a5c9;
  --line: #2f2347;
  --purple: #a855f7;
  --accent: #c084fc;
  --on-accent: #0a0612;
  --danger: #ff8aa0;
  --font: 'Archivo', 'Arial Narrow', system-ui, -apple-system, 'Segoe UI', sans-serif;
  color-scheme: dark;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font);
  font-size: 1rem;
  line-height: 1.5;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

button,
input,
textarea {
  font: inherit;
  color: inherit;
}

button {
  cursor: pointer;
}

:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* ---------- Home: pinned logo bar, video hero, shop info, footer ---------- */
:root {
  --brand-h: calc(84px + env(safe-area-inset-top, 0px));
}

/* Logo bar. Sticky, so it follows the page while scrolling. The logo sits in the
   middle column and the social links on the right. */
.brand {
  position: sticky;
  top: 0;
  z-index: 10;
  height: var(--brand-h);
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  padding: env(safe-area-inset-top, 0px) 16px 0;
  background: rgba(10, 6, 18, 0.92);
  -webkit-backdrop-filter: blur(10px);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}

.logo {
  margin: 0;
  width: min(100%, 880px);
}

.brand .logo {
  grid-column: 2;
  width: auto;
  height: 60px;
}

.logo svg {
  display: block;
  width: 100%;
  height: auto;
  filter: drop-shadow(0 0 3px var(--purple));
}

.brand .logo svg {
  width: auto;
  height: 100%;
}

.logo-link {
  display: block;
  height: 100%;
  color: inherit;
  border-radius: 6px;
}

.logo path {
  fill: var(--ink);
  stroke: var(--purple);
  stroke-width: 6;
  stroke-linejoin: round;
  paint-order: stroke;
}

.brand .socials {
  grid-column: 3;
  justify-self: end;
}

.socials {
  display: flex;
  align-items: center;
  gap: 2px;
}

.social {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  color: var(--ink);
  border-radius: 50%;
}

.social:hover {
  color: var(--accent);
}

/* The hero fills whatever is left of the first screen under the pinned bar. */
.hero {
  position: relative;
  height: calc(100vh - var(--brand-h));
  height: calc(100svh - var(--brand-h));
  min-height: 440px;
  overflow: hidden;
  background: var(--bg);
}

/* Blurred, dimmed poster fills the sides when the screen is wider than the video. */
.hero-backdrop {
  position: absolute;
  top: -48px;
  left: -48px;
  width: calc(100% + 96px);
  height: calc(100% + 96px);
  object-fit: cover;
  filter: blur(36px) brightness(0.5) saturate(1.2);
}

.hero-video {
  position: absolute;
  top: 0;
  left: 50%;
  /* Much taller than the window (165%): --pan (0 to 1, set while scrolling) slides the
     footage up through the extra 65% (that is 39.4% of the video's own height), so the
     view travels from the top of the video to the bottom. */
  transform: translate3d(-50%, calc(var(--pan, 0) * -39.4%), 0);
  will-change: transform;
  height: 165%;
  width: auto;
  max-width: 100%;
  aspect-ratio: 720 / 1084;
  object-fit: cover;
  background: var(--surface);
}

/* Soft shade behind the button so it reads over any frame of the video. */
.hero::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(ellipse 60% 40% at 50% 50%, rgba(10, 6, 18, 0.55), rgba(10, 6, 18, 0) 70%);
}

.hero-cta {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  pointer-events: none;
}

.hero .book-now {
  pointer-events: auto;
  max-width: min(88vw, 460px);
  padding: 20px 44px;
  font-size: clamp(1.15rem, 4.6vw, 1.5rem);
  line-height: 1.15;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  animation: ring 2.8s ease-out infinite;
}

@keyframes ring {
  0% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 0 rgba(192, 132, 252, 0.55);
  }
  70%,
  100% {
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), 0 0 0 22px rgba(192, 132, 252, 0);
  }
}

.hero-toggle {
  position: absolute;
  right: 14px;
  bottom: 14px;
  z-index: 2;
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  color: var(--ink);
  background: rgba(10, 6, 18, 0.6);
  border: 2px solid rgba(246, 239, 255, 0.7);
  border-radius: 50%;
}

.hero-toggle:hover {
  border-color: var(--ink);
}

.info {
  max-width: 960px;
  margin: 0 auto;
  padding: 72px 20px 48px;
}

.info-grid {
  display: grid;
  grid-template-columns: 1.2fr 1fr;
  gap: 48px;
}

.info h2 {
  margin: 0 0 14px;
  font-size: 1.5rem;
  font-weight: 800;
  font-variation-settings: 'wdth' 85;
}

.menu,
.hours {
  margin: 0 0 32px;
  padding: 0;
  list-style: none;
  border-top: 2px solid var(--ink);
}

.menu li {
  padding: 14px 0;
  border-bottom: 1px solid var(--line);
}

.menu-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
}

.menu-name {
  font-weight: 700;
}

.menu-leader {
  flex: 1;
  min-width: 12px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.menu-price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.menu-meta {
  margin: 2px 0 0;
  font-size: 0.9rem;
  color: var(--muted);
}

.hours li {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 10px 0;
  border-bottom: 1px solid var(--line);
  font-variant-numeric: tabular-nums;
}

.hours li span:last-child {
  text-align: right;
}

.hours .closed {
  color: var(--muted);
}

.info address {
  font-style: normal;
  color: var(--muted);
}

.info-cta {
  display: flex;
  justify-content: center;
  margin-top: 40px;
}

.site-foot {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  padding: 32px 20px calc(36px + env(safe-area-inset-bottom, 0px));
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 0.9rem;
}

.site-foot .copy {
  margin: 0;
  font-weight: 700;
  letter-spacing: 0.04em;
}

/* Social links along the bottom of the video. */
.hero-socials {
  position: absolute;
  left: 50%;
  bottom: 14px;
  z-index: 2;
  transform: translateX(-50%);
}

.hero-socials .socials {
  padding: 2px 8px;
  background: rgba(10, 6, 18, 0.6);
  border: 1px solid rgba(246, 239, 255, 0.25);
  border-radius: 999px;
}

/* Scroll reveal: content below the video fades up as it enters the screen. */
.reveal {
  opacity: 0;
  transform: translateY(28px);
  transition: opacity 0.7s ease, transform 0.7s cubic-bezier(0.2, 0.7, 0.2, 1);
  transition-delay: var(--d, 0ms);
}

.reveal.in {
  opacity: 1;
  transform: none;
}

/* Branded CTA on each haircut type: a purple box, matching the other booking buttons. */
.svc-cta {
  display: inline-block;
  margin-top: 12px;
  padding: 12px 24px;
  font-weight: 800;
  text-align: center;
  color: var(--on-accent);
  text-decoration: none;
  background: var(--accent);
  border: 2px solid var(--accent);
  border-radius: 8px;
}

.svc-cta:hover {
  filter: brightness(1.08);
}

/* Words that drop down into place instead of lifting up. */
.reveal-down {
  transform: translateY(-28px);
}

/* Photo section under the video. The photo is 130% of the section's height and slides
   through it with --pan (see Statement.jsx), so it has its own parallax. The headline sits
   at the top and the stacked words at the bottom, which keeps the faces clear in the middle. */
.statement {
  position: relative;
  display: flex;
  min-height: 780px;
  min-height: max(780px, 100svh);
  padding: 56px 20px 48px;
  overflow: hidden;
  background: var(--bg);
}

.statement-img {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 130%;
  object-fit: cover;
  object-position: 20% 50%;
  transform: translate3d(0, calc(var(--pan, 0.5) * -23.1%), 0);
  will-change: transform;
}

/* Darkens the top and bottom where the text sits, leaves the middle (the faces) clear. */
.statement::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: linear-gradient(
    to bottom,
    rgba(10, 6, 18, 0.78) 0%,
    rgba(10, 6, 18, 0.35) 28%,
    rgba(10, 6, 18, 0) 45%,
    rgba(10, 6, 18, 0) 55%,
    rgba(10, 6, 18, 0.55) 72%,
    rgba(10, 6, 18, 0.9) 100%
  );
}

.statement-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 32px;
  width: 100%;
  max-width: 1100px;
  margin: 0 auto;
}

.statement h2 {
  max-width: 18ch;
  margin: 0 0 14px;
  font-size: clamp(1.5rem, 5.2vw, 2.6rem);
  font-weight: 900;
  line-height: 1.08;
  letter-spacing: 0.01em;
  font-variation-settings: 'wdth' 85;
  text-shadow: 0 2px 18px rgba(0, 0, 0, 0.6);
}

.statement p {
  max-width: 44ch;
  margin: 0;
  font-size: clamp(1rem, 2.6vw, 1.2rem);
  text-shadow: 0 2px 14px rgba(0, 0, 0, 0.7);
}

.statement-words {
  margin: 0;
  padding: 0;
  list-style: none;
}

.statement-words li {
  font-size: clamp(2.7rem, 13vw, 6.8rem);
  font-weight: 900;
  line-height: 0.98;
  letter-spacing: -0.01em;
  font-variation-settings: 'wdth' 70;
  text-shadow: 0 4px 24px rgba(0, 0, 0, 0.55);
}

.statement-words .statement-place {
  color: var(--accent);
}

@media (min-width: 900px) {
  .statement {
    min-height: max(720px, 90svh);
  }

  /* On wide screens the words sit on the left, so shade the left side as well. */
  .statement::after {
    background: linear-gradient(90deg, rgba(10, 6, 18, 0.75) 0%, rgba(10, 6, 18, 0.4) 40%, rgba(10, 6, 18, 0) 70%),
      linear-gradient(
        to bottom,
        rgba(10, 6, 18, 0.6) 0%,
        rgba(10, 6, 18, 0) 30%,
        rgba(10, 6, 18, 0) 60%,
        rgba(10, 6, 18, 0.7) 100%
      );
  }
}

@media (max-width: 760px) {
  .info-grid {
    grid-template-columns: 1fr;
    gap: 36px;
  }
}

@media (max-width: 520px) {
  .hero .book-now {
    padding: 16px 32px;
  }
}

@media (prefers-reduced-motion: reduce) {
  .hero .book-now {
    animation: none;
  }

  .reveal,
  .reveal-down {
    opacity: 1;
    transform: none;
    transition: none;
  }
}

/* ---------- Buttons ---------- */
.btn {
  display: inline-block;
  padding: 13px 24px;
  border: 2px solid var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--ink);
  font-weight: 700;
  text-align: center;
  text-decoration: none;
}

.btn:not(:disabled):hover {
  border-color: var(--accent);
}

.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.btn-primary {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.btn-primary:not(:disabled):hover {
  filter: brightness(1.08);
}

.book-now {
  padding: 18px 64px;
  border-radius: 999px;
  font-size: 1.35rem;
  font-weight: 800;
  letter-spacing: 0.01em;
}

/* ---------- Booking ---------- */
.book {
  max-width: 640px;
  margin: 0 auto;
  padding: calc(24px + env(safe-area-inset-top, 0px)) 20px 72px;
}

.back {
  display: inline-block;
  margin-bottom: 8px;
  color: var(--muted);
  text-decoration: none;
  padding: 6px 0;
}

.back:hover {
  color: var(--ink);
}

.book-title {
  margin: 0 0 20px;
  font-size: clamp(2rem, 7vw, 2.8rem);
  font-weight: 900;
  line-height: 1.05;
  font-variation-settings: 'wdth' 85;
}

.steps {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.steps button {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: none;
  border: 2px solid var(--line);
  border-radius: 999px;
  color: var(--muted);
  font-weight: 600;
  font-size: 0.92rem;
}

.steps button[aria-current='step'] {
  border-color: var(--accent);
  color: var(--ink);
}

.steps button.done {
  color: var(--ink);
}

.steps button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.steps .n {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--line);
  font-size: 0.8rem;
}

.steps [aria-current='step'] .n {
  background: var(--accent);
  color: var(--on-accent);
}

.panel {
  background: var(--surface);
  border: 2px solid var(--line);
  border-radius: 10px;
  padding: 22px;
}

.panel h2 {
  margin: 0 0 16px;
  font-size: 1.4rem;
  font-weight: 800;
}

.opt {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 10px;
  width: 100%;
  margin-bottom: 10px;
  padding: 14px;
  text-align: left;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.opt:hover {
  border-color: var(--accent);
}

.opt[aria-pressed='true'] {
  border-color: var(--accent);
  box-shadow: inset 4px 0 0 var(--accent);
}

.opt .name {
  font-weight: 700;
}

.opt .meta {
  color: var(--muted);
  font-size: 0.9rem;
}

.opt .leader {
  flex: 1;
  min-width: 16px;
  border-bottom: 2px dotted var(--line);
  transform: translateY(-4px);
}

.opt .price {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.opt .note {
  flex-basis: 100%;
  margin-top: 2px;
  font-size: 0.88rem;
  font-weight: 400;
  color: var(--muted);
}

.days {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  padding: 2px 2px 12px;
  overflow-x: auto;
}

.day {
  flex: none;
  width: 72px;
  padding: 10px 6px;
  text-align: center;
  line-height: 1.2;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.day .dow {
  display: block;
  font-size: 0.85rem;
  color: var(--muted);
}

.day .dom {
  display: block;
  font-size: 1.4rem;
  font-weight: 800;
}

.day .tag {
  display: block;
  min-height: 1em;
  font-size: 0.75rem;
  color: var(--muted);
}

.day[aria-pressed='true'] {
  border-color: var(--accent);
}

.day:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.times {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(98px, 1fr));
  gap: 8px;
  margin: 12px 0 4px;
}

.time {
  padding: 10px 6px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.time:hover {
  border-color: var(--accent);
}

.time[aria-pressed='true'] {
  background: var(--accent);
  border-color: var(--accent);
  color: var(--on-accent);
}

.empty {
  padding: 18px;
  color: var(--muted);
  border: 2px dashed var(--line);
  border-radius: 8px;
}

.summary {
  margin: 0 0 20px;
  padding: 14px 16px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.summary div + div {
  margin-top: 10px;
}

.summary dt {
  font-size: 0.85rem;
  color: var(--muted);
}

.summary dd {
  margin: 0;
  font-weight: 600;
}

.field {
  margin-bottom: 14px;
}

.field label {
  display: block;
  margin-bottom: 4px;
  font-weight: 600;
}

.field input,
.field textarea {
  width: 100%;
  padding: 12px;
  background: var(--bg);
  border: 2px solid var(--line);
  border-radius: 8px;
}

.field input:focus,
.field textarea:focus {
  border-color: var(--accent);
}

.field input[aria-invalid='true'] {
  border-color: var(--danger);
}

.hint {
  font-weight: 400;
  font-size: 0.85rem;
  color: var(--muted);
}

.err {
  min-height: 1.3em;
  margin: 4px 0 0;
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--danger);
}

.notice {
  margin: 0 0 16px;
  padding: 12px 14px;
  font-weight: 600;
  color: var(--danger);
  border: 2px solid var(--danger);
  border-radius: 8px;
}

.muted {
  color: var(--muted);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 20px;
}

.done {
  padding-top: 24px;
}

.done p {
  margin: 0 0 8px;
}

.code {
  display: inline-block;
  margin: 4px 0 16px !important;
  padding: 6px 14px;
  font-weight: 800;
  letter-spacing: 0.06em;
  border: 2px dashed var(--accent);
  border-radius: 8px;
}

.done .btn {
  margin-top: 16px;
}

@media (max-width: 520px) {
  .book-now {
    padding: 16px 48px;
  }
  .panel {
    padding: 16px;
  }
}

@media (prefers-reduced-motion: reduce) {
  html {
    scroll-behavior: auto;
  }
}
VICBLESS_EOF

echo ""
echo "Files updated. Running tests..."
npm test
echo ""
if [ ! -f public/media/vicbless-cutting-hair.jpg ]; then
  echo "REMINDER: copy vicbless-cutting-hair.jpg into public/media/ or the photo will not show."
fi
echo "Next: npm run dev -- --host"
echo ""
echo "Git commands (not run for you):"
echo "  git add -A"
echo "  git commit -m \"Add photo section with parallax and stacked words\""
echo "  git push"
