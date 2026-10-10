import { useState } from 'react'
import LoopingLogo from './LoopingLogo.jsx'
import Greeting from './Greeting.jsx'
import { signIn } from './mockAdminApi.js'

export default function SignIn({ greeting, onSignedIn }) {
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(e) {
    e.preventDefault()
    setBusy(true)
    setError('')
    try {
      await signIn(password)
      onSignedIn()
    } catch (ex) {
      setError(ex.message)
      setBusy(false)
    }
  }

  return (
    <main className="admin admin-signin">
      <LoopingLogo variant="hero" />

      <Greeting message={greeting} />
      <p className="admin-lede">Sign in to see the schedule.</p>

      <form onSubmit={submit} noValidate>
        <div className="field">
          <label htmlFor="admin-password">Password</label>
          <input
            id="admin-password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            aria-invalid={!!error}
            aria-describedby="admin-password-error"
          />
          <p className="err" id="admin-password-error" role={error ? 'alert' : undefined}>
            {error}
          </p>
        </div>
        <button type="submit" className="btn btn-primary" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>

      <p className="admin-preview-note">Preview: any password works until the backend is connected.</p>
      <p>
        <a href="#/">Back to the site</a>
      </p>
    </main>
  )
}
