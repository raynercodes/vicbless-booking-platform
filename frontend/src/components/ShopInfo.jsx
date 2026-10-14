import EmailLink from './EmailLink.jsx'
import Reveal from './Reveal.jsx'
import { BUSINESS, CTA_TEXT, HOURS } from '../config.js'
import { fmtTime } from '../lib/availability.js'
import { priceLabel } from '../lib/format.js'
import { useShopSettings } from '../lib/useShopSettings.js'

// Monday first, the way people read a week.
const DAYS = [
  [1, 'Monday'],
  [2, 'Tuesday'],
  [3, 'Wednesday'],
  [4, 'Thursday'],
  [5, 'Friday'],
  [6, 'Saturday'],
  [0, 'Sunday'],
]

export default function ShopInfo() {
  // The services and prices are Vic's own (he edits them in his dashboard).
  const { services } = useShopSettings()
  return (
    <section className="info" aria-label="Services and hours">
      <div className="info-grid">
        <div>
          <Reveal as="h2">Services</Reveal>
          <ul className="menu">
            {services.map((s, i) => (
              <Reveal as="li" key={s.id} delay={i * 80}>
                <div className="menu-row">
                  <span className="menu-name">{s.name}</span>
                  <span className="menu-leader" />
                  <span className="menu-price">{priceLabel(s)}</span>
                </div>
                {s.note && <p className="menu-meta">{s.note}</p>}
                <a className="svc-cta" href={`#/book?service=${s.id}`}>
                  {CTA_TEXT}
                </a>
              </Reveal>
            ))}
          </ul>
        </div>

        <div>
          <Reveal as="h2">Hours</Reveal>
          <Reveal as="ul" className="hours" delay={80}>
            {DAYS.map(([i, name]) => {
              const windows = HOURS[i]
              return (
                <li key={i}>
                  <span>{name}</span>
                  <span className={windows ? '' : 'closed'}>
                    {windows ? windows.map(([a, b]) => `${fmtTime(a)} to ${fmtTime(b)}`).join(', ') : 'Closed'}
                  </span>
                </li>
              )
            })}
          </Reveal>

          <Reveal as="h2">Vic's Shop Location</Reveal>
          <Reveal as="address" delay={80}>
            {BUSINESS.address.map((line) => (
              <span key={line}>
                {line}
                <br />
              </span>
            ))}
            <EmailLink />
          </Reveal>
        </div>
      </div>

      <Reveal className="info-cta">
        <a className="btn btn-primary" href="#/book">
          {CTA_TEXT}
        </a>
      </Reveal>
    </section>
  )
}
