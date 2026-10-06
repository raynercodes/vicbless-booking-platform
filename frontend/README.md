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
