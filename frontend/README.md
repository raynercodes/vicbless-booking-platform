# Vicbless Booking Platform

Frontend for Vicbless Barbershop. Home page (logo, presentation video, Book Now) and a booking flow for Vic. React + Vite, mock data layer, no backend yet.

## Run it

```bash
npm install
npm run dev       # http://localhost:5173
npm test          # availability logic tests
npm run build     # production build in dist/
```

## Media files

Put these two files in `public/media/` (they are too large to generate with the setup script):

- `vicbless-presentation.mp4` (muted H.264 video)
- `vicbless-poster.jpg` (still shown while the video loads)

## Where things live

- `src/config.js`: services, hours, staff, phone, address. Hours, services, address and social links are Vic's real ones; the phone number is still a placeholder.
- `src/lib/availability.js`: pure scheduling logic (tested).
- `src/lib/api.js`: mock data layer. The only file to replace when the backend exists (`GET /availability`, `POST /bookings`).
- `src/components/logoPath.js`: the approved logo as SVG outlines.
- `src/pages/Home.jsx` and `src/pages/Book.jsx`: the two screens.

## Mock data vs the real API

The site has two data layers behind the same functions, so the pages never know which one they are using:

| Layer | Files | Used when |
| --- | --- | --- |
| Mock (fake data kept in the browser) | `lib/mockApi.js`, `lib/mockStore.js`, `admin/mockAdminApi.js` | `npm run dev` and `npm test` |
| Real (the backend API) | `lib/realApi.js`, `admin/realAdminApi.js`, `lib/http.js` | production builds (`npm run build`, the deploy workflow) |

The pages import from `lib/api.js` and `admin/adminApi.js`, which pick the layer (see `lib/mode.js`).
The choice is made while the site is built, so a live site cannot end up on the mock by accident.

Try the site against a real backend while developing. Start the API on port 8000, then:

```bash
VITE_API_MODE=real VITE_API_PROXY=http://127.0.0.1:8000 npm run dev
```

The site and the API share one address in production (CloudFront sends `/api/*` to the backend), so every
call is a relative `/api/...` URL and the dev server forwards `/api` the same way. There is no API address to configure.
