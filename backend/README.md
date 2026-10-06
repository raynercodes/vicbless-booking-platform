# Backend

Not built yet. This will replace the mock data layer in `frontend/src/lib/api.js`.

The frontend already defines what it needs:

- `GET /availability?from=YYYY-MM-DD&to=YYYY-MM-DD` returns the busy time blocks per day
- `POST /bookings` creates a booking, and returns 409 when the time was just taken
