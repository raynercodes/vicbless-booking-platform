import { useEffect, useState } from 'react'
import Home from './pages/Home.jsx'
import Book from './pages/Book.jsx'

const readPath = () => window.location.hash.replace(/^#/, '') || '/'
const isBookingPath = (path) => path.startsWith('/book')

// Home lives at the plain address, with no "#/" showing. Anything that lands on home with a
// leftover "#/" (the Back to home links, an old bookmark, or editing the address bar while
// already on home) is cleaned up in place, without adding a history entry, so the Back
// button still works as expected.
function cleanHomeAddress() {
  if (!isBookingPath(readPath()) && window.location.hash) {
    window.history.replaceState(null, '', window.location.pathname + window.location.search)
  }
}

function useHashPath() {
  const [path, setPath] = useState(readPath)
  useEffect(() => {
    cleanHomeAddress() // first load
    const onChange = () => {
      setPath(readPath())
      window.scrollTo(0, 0)
      cleanHomeAddress()
    }
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  return path
}

export default function App() {
  const path = useHashPath()
  return isBookingPath(path) ? <Book /> : <Home />
}
