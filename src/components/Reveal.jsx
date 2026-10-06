import { useEffect, useRef, useState } from 'react'

// Fades and lifts its content in once it scrolls into view.
// Shows immediately when the browser has no IntersectionObserver or the visitor
// prefers reduced motion, so nothing is ever left hidden.
export default function Reveal({ as: Tag = 'div', delay = 0, className = '', children, ...rest }) {
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

  return (
    <Tag
      ref={ref}
      className={`reveal${shown ? ' in' : ''}${className ? ` ${className}` : ''}`}
      style={{ '--d': `${delay}ms` }}
      {...rest}
    >
      {children}
    </Tag>
  )
}
