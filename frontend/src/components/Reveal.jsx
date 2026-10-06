import { useEffect, useRef, useState } from 'react'
import { getSettings } from '../lib/useSettings.js'

// Fades and moves its content in once it scrolls into view.
//   from="below" (default) lifts up into place, from="above" drops down into place.
// Shows immediately when the browser has no IntersectionObserver or Motion is off in the
// settings (which starts from the visitor's system setting), so nothing is left hidden.
export default function Reveal({ as: Tag = 'div', from = 'below', delay = 0, className = '', children, ...rest }) {
  const ref = useRef(null)
  const [shown, setShown] = useState(
    () => typeof window === 'undefined' || !('IntersectionObserver' in window) || getSettings().motion === 'off',
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
