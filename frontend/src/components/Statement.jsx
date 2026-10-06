import { useEffect, useRef } from 'react'
import Reveal from './Reveal.jsx'
import { STATEMENT } from '../config.js'
import { useSettings } from '../lib/useSettings.js'

// Photo section with its own parallax. --pan goes 0 to 1 as the section travels from
// entering the bottom of the screen to leaving the top, and slides the (taller) photo
// through the section. Skipped when Motion is off, which leaves the photo centred.
export default function Statement() {
  const ref = useRef(null)
  const { motion } = useSettings()

  useEffect(() => {
    const el = ref.current
    if (!el || motion === 'off') return undefined

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
  }, [motion])

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
