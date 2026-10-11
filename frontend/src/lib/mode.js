// Which data layer the site uses: 'real' talks to the backend API, 'mock' fakes everything in the browser.
//
//   production build (npm run build)   real
//   npm run dev, npm test              mock   (no backend needed)
//   VITE_API_MODE=real npm run dev     real   (with the dev proxy, see vite.config.js)
//
// The choice is made while the site is built, so a live site can never end up on the mock by accident.

const forced = import.meta.env.VITE_API_MODE
export const API_MODE = forced === 'mock' || forced === 'real' ? forced : import.meta.env.PROD ? 'real' : 'mock'
