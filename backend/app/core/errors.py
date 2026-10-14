"""Errors the API turns into the JSON shape { "error": { "code", "message" } }.

Each error carries three things the site needs:
  status   the HTTP status code
  code     a short stable word the frontend can branch on (for example "slot_taken")
  message  a sentence that is safe to show a customer or Vic as it is, so keep them friendly and plain
Raise one of these from anywhere in the app; core/web.py turns it into the response.
"""

from .brand import CONTACT_EMAIL


class ApiError(Exception):
    status = 400
    code = "bad_request"

    field: str | None = None  # which form field the problem is about, when it is about one

    def __init__(self, message: str | None = None, *, code: str | None = None, field: str | None = None):
        super().__init__(message or self.default_message)
        self.message = message or self.default_message
        if code:
            self.code = code
        if field:
            self.field = field

    default_message = "Something went wrong with that request. Please try again."


class ValidationFailed(ApiError):
    status = 422
    code = "validation_error"
    default_message = "Some of the details aren't valid. Please check them and try again."


class InvalidSlot(ApiError):
    """The time can never be booked: closed day, off the grid, or does not fit in the day."""

    status = 422
    code = "invalid_slot"
    default_message = "That isn't a time Vic takes bookings for. Please pick another."


class SlotUnavailable(ApiError):
    """The time could be booked in general but not right now: past, too soon, or too far ahead."""

    status = 409
    code = "slot_unavailable"
    default_message = "That time is no longer available. Please pick another."


class SlotTaken(ApiError):
    status = 409
    code = "slot_taken"
    default_message = "Sorry, that time was just taken. Please pick another."


class Conflict(ApiError):
    status = 409
    code = "conflict"
    default_message = "That overlaps a booking or time you already blocked off."


class NotFound(ApiError):
    status = 404
    code = "not_found"
    default_message = "We couldn't find that."


class Unauthorized(ApiError):
    status = 401
    code = "unauthorized"
    default_message = "Please sign in to continue."


class TooManyBookings(ApiError):
    status = 429
    code = "too_many_bookings"
    default_message = f"This phone number already has the most upcoming bookings we allow. Please email Vic at {CONTACT_EMAIL} to change one."


class TooManyAttempts(ApiError):
    status = 429
    code = "too_many_attempts"
    default_message = "Too many tries. Please wait about 15 minutes, then try again."


class NotConfigured(ApiError):
    status = 503
    code = "not_configured"
    default_message = "This part of the service isn't set up yet."
