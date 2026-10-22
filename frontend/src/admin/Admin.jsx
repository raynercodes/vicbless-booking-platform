import { useEffect, useState } from 'react'
import './admin.css'
import SiteMenu from '../components/SiteMenu.jsx'
import { copyrightLine } from '../lib/format.js'
import Greeting from './Greeting.jsx'
import Schedule from './Schedule.jsx'
import SalesPage from './SalesPage.jsx'
import SettingsPanel from './SettingsPanel.jsx'
import SignIn from './SignIn.jsx'
import LoopingLogo from './LoopingLogo.jsx'
import { pickGreeting } from './greetings.js'
import { API_MODE } from '../lib/mode.js'
import { SIGNED_OUT_EVENT, isSignedIn, signOut } from './adminApi.js'

const LAST_GREETING_KEY = 'vicbless.admin.lastGreeting'

function readLastGreeting() {
  try {
    return localStorage.getItem(LAST_GREETING_KEY) || ''
  } catch {
    return ''
  }
}

export default function Admin() {
  const [signedIn, setSignedIn] = useState(isSignedIn)
  const [view, setView] = useState('schedule') // 'schedule' | 'sales' (the two tabs) | 'settings' (Menu > Settings > Shop settings)

  // One greeting per visit: the sign-in screen and the dashboard show the same one, and the next
  // visit gets a different one.
  const [greeting] = useState(() => pickGreeting({ last: readLastGreeting() }))
  useEffect(() => {
    try {
      localStorage.setItem(LAST_GREETING_KEY, greeting)
    } catch {
      /* storage blocked: the next visit may repeat it, which is harmless */
    }
  }, [greeting])

  // The session ran out (or the API refused it): back to the sign-in screen instead of a dashboard that cannot load.
  useEffect(() => {
    const out = () => setSignedIn(false)
    window.addEventListener(SIGNED_OUT_EVENT, out)
    return () => window.removeEventListener(SIGNED_OUT_EVENT, out)
  }, [])

  // Keep the page out of search results, and give the tab its own title while it is open.
  useEffect(() => {
    const previousTitle = document.title
    document.title = "Vic's dashboard"
    const meta = document.createElement('meta')
    meta.name = 'robots'
    meta.content = 'noindex, nofollow'
    document.head.appendChild(meta)
    return () => {
      document.title = previousTitle
      meta.remove()
    }
  }, [])

  if (!signedIn) return <SignIn greeting={greeting} onSignedIn={() => setSignedIn(true)} />

  return (
    <main className={view === 'sales' ? 'admin admin-wide' : 'admin'}>
      <header className="admin-bar">
        <SiteMenu
          settingsExtra={({ close }) => (
            <button
              type="button"
              className="menu-link"
              onClick={() => {
                setView('settings')
                close()
                window.scrollTo?.({ top: 0 })
              }}
            >
              Shop settings
            </button>
          )}
        >
          <a className="menu-link" href="#/">
            View site
          </a>
          <button
            type="button"
            className="menu-link"
            onClick={() => {
              signOut()
              setSignedIn(false)
            }}
          >
            Sign out
          </button>
        </SiteMenu>
        <LoopingLogo variant="bar" />
        <span aria-hidden="true" />
      </header>

      <Greeting message={greeting} />

      {API_MODE === 'mock' && (
        <p className="admin-preview-note">
          Preview data. Bookings made on the site in this browser show up here, along with sample ones marked "sample". Cancelling and blocking time work too, and are saved in this browser only.
        </p>
      )}

      {view !== 'settings' && (
        <nav className="admin-tabs" aria-label="Dashboard pages">
          {[
            ['schedule', 'Schedule'],
            ['sales', 'Sales log'],
          ].map(([id, label]) => (
            <button key={id} type="button" aria-current={view === id ? 'page' : undefined} onClick={() => setView(id)}>
              {label}
            </button>
          ))}
        </nav>
      )}

      {view === 'settings' ? <SettingsPanel onClose={() => setView('schedule')} /> : view === 'sales' ? <SalesPage /> : <Schedule />}

      <footer className="admin-foot">{copyrightLine()}</footer>
    </main>
  )
}
