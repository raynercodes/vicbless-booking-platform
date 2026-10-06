import { useEffect, useState } from 'react'
import Home from './pages/Home.jsx'
import Book from './pages/Book.jsx'

const readPath = () => window.location.hash.replace(/^#/, '') || '/'

function useHashPath() {
  const [path, setPath] = useState(readPath)
  useEffect(() => {
    const onChange = () => {
      setPath(readPath())
      window.scrollTo(0, 0)
    }
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  return path
}

export default function App() {
  const path = useHashPath()
  return path.startsWith('/book') ? <Book /> : <Home />
}
