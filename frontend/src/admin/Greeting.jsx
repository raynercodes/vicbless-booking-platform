import Reveal from '../components/Reveal.jsx'
import { splitName } from './greetings.js'

// The big welcome line. It is the page heading, and Vic's name is shown in the accent colour.
export default function Greeting({ message }) {
  return (
    <Reveal as="h1" from="above" className="admin-greeting">
      {splitName(message).map((part, i) =>
        part.accent ? (
          <span key={i} className="admin-name">
            {part.text}
          </span>
        ) : (
          part.text
        ),
      )}
    </Reveal>
  )
}
