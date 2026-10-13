import { useEffect, useRef, useState } from 'react'
import SiteHeader from '../components/SiteHeader.jsx'
import SiteFooter from '../components/SiteFooter.jsx'
import ShopInfo from '../components/ShopInfo.jsx'
import Statement from '../components/Statement.jsx'
import { useSettings } from '../lib/useSettings.js'
import Socials from '../components/Socials.jsx'
import { CTA_TEXT, HOME_ORDER, HOME_TAGLINE } from '../config.js'

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

// Which comes first: the photo section or the video (HOME_ORDER in config.js).
const PHOTO_FIRST = HOME_ORDER === 'photo-first'

// The pan finishes after the visitor has scrolled 85% of the video's height,
// so the movement reads as stronger and faster.
const PAN_DISTANCE = 0.85

export default function Home() {
  const reduceMotion = useSettings().motion === 'off'
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
  // (--pan goes 0 to 1 over the first 85% of the hero's height of scrolling). Skipped when Motion is off.
  useEffect(() => {
    if (reduceMotion) return undefined
    const hero = heroRef.current
    if (!hero) return undefined
    let frame = 0
    const update = () => {
      frame = 0
      const h = hero.offsetHeight || 1
      // The pan starts once the video has scrolled up to where it rests under the logo bar. With the video first
      // that is the very top of the page (start = 0); with the photo first it is the height of the photo section.
      const main = hero.parentElement
      const start = main ? hero.getBoundingClientRect().top - main.getBoundingClientRect().top : 0
      const p = Math.min(1, Math.max(0, (window.scrollY - start) / (h * PAN_DISTANCE)))
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
        {PHOTO_FIRST && <Statement />}

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

          {HOME_TAGLINE.length > 0 && (
            <p className="hero-tagline">
              {HOME_TAGLINE.map((line, i) => (
                <span
                  key={line}
                  className={HOME_TAGLINE.length > 1 && i === HOME_TAGLINE.length - 1 ? 'hero-tagline-accent' : undefined}
                  style={{ '--i': i }}
                >
                  {line}{' '}
                </span>
              ))}
            </p>
          )}

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

        {!PHOTO_FIRST && <Statement />}

        <ShopInfo />
      </main>

      <SiteFooter />
    </>
  )
}
