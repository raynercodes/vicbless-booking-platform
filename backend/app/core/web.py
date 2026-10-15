"""Plumbing every request goes through: error JSON, security headers, request ids, body size, CORS.

Nothing in here is about bookings. It makes sure every response, success or failure, looks the same
and carries the same safety headers.
"""

from __future__ import annotations

import logging
import time
import traceback
import uuid

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import config
from .errors import ApiError
from .logs import log, request_id

# A booking is a few hundred bytes. Refusing anything bigger than 16 KB stops oversized junk early.
MAX_BODY_BYTES = 16 * 1024

# Added to every response. no-store means browsers and CloudFront never cache API answers
# (a cached availability list could show a time as free after it was taken).
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
}


def error_response(status: int, code: str, message: str, **extra) -> JSONResponse:
    """Every error looks like { "error": { "code", "message", ... } } so the site only needs one way to read them."""
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message, **extra}})


def add_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError):
        extra = {"field": exc.field} if exc.field else {}
        # Why a request was refused (slot_taken, invalid_slot, unauthorized ...), so CloudWatch shows more than a status number.
        log("api_error", logging.WARNING if exc.status >= 500 else logging.INFO, code=exc.code, status=exc.status, field=exc.field or "")
        return error_response(exc.status, exc.code, exc.message, **extra)

    @app.exception_handler(RequestValidationError)
    async def _invalid(_: Request, exc: RequestValidationError):
        # Only the first problem is reported, so the person fixes one thing at a time.
        first = exc.errors()[0] if exc.errors() else {}
        field = ".".join(str(p) for p in first.get("loc", ()) if p not in ("body", "query"))
        log("validation_failed", field=field, kind=first.get("type", ""))  # which field, never what was typed
        if first.get("type") == "value_error":
            # Our own validators (schemas/requests.py) wrote this sentence for people. Show it as it is.
            message = str(first.get("msg", "")).removeprefix("Value error, ")
        else:
            # Pydantic's own wording ("Input should be a valid integer") is for programmers, so replace it.
            message = "Some of the details aren't valid. Please check them and try again."
        return error_response(422, "validation_error", message, field=field)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException):
        codes = {404: "not_found", 405: "method_not_allowed"}
        message = "We couldn't find that." if exc.status_code == 404 else "That isn't allowed."
        return error_response(exc.status_code, codes.get(exc.status_code, "error"), message)


def add_middleware(app: FastAPI) -> None:
    # CORS: which websites may call this API from a browser. Set per environment from the template.
    # No cookies are used (admin sends a Bearer token), so credentials stay off.
    origins = config.get_settings().cors_origins
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(origins),
            allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type"],
            allow_credentials=False,
            max_age=600,
        )

    # One wrapper around every request: tag it with an id, refuse oversized bodies, turn surprises into
    # a clean 500, add the safety headers, and write one log line (never with names, phones or emails).
    @app.middleware("http")
    async def _wrap(request: Request, call_next):
        # The id ties together every log line from one request, and is sent back so a problem can be traced.
        rid = request.headers.get("x-amzn-trace-id") or uuid.uuid4().hex
        token = request_id.set(rid[:64])
        started = time.perf_counter()
        try:
            length = request.headers.get("content-length")
            if length and length.isdigit() and int(length) > MAX_BODY_BYTES:
                response = error_response(413, "payload_too_large", "That request is too big.")
            else:
                try:
                    response = await call_next(request)
                except Exception as exc:
                    # Where it happened (file:line function, innermost last) but never the error's own text, which could
                    # contain what a customer typed.
                    frames = [f"{f.filename.split('/')[-1]}:{f.lineno} {f.name}" for f in traceback.extract_tb(exc.__traceback__)][-8:]
                    log("unhandled_error", logging.ERROR, errorType=type(exc).__name__, path=request.url.path, frames=frames)
                    # The real error goes to the logs only. The caller never sees internal details.
                    response = error_response(500, "server_error", "Something went wrong on our side. Please try again.")
            for name, value in SECURITY_HEADERS.items():
                response.headers.setdefault(name, value)
            response.headers["X-Request-Id"] = rid[:64]
            log(
                "request",
                method=request.method,
                path=request.url.path,
                status=response.status_code,
                ms=round((time.perf_counter() - started) * 1000),
            )
            return response
        finally:
            request_id.reset(token)
