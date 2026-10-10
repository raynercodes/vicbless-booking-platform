"""Builds the app. Every route lives under /api. There is no /docs, /redoc or openapi.json in any environment.

Where things live (each layer only talks to the ones below it):
    routes/     the URLs: read the request, call a service, shape the answer
    services/   what happens: booking, blocking, signing in, emailing
    database/   everything that touches DynamoDB
    domain/     the shop's rules (shop.py) and its things (models.py), no web or AWS
    schemas/    what the site is allowed to send
    core/       settings, secrets, security, logging, errors, web plumbing
    emailing/   email providers (Resend today, SES later)
"""

from fastapi import FastAPI

from .core.web import add_error_handlers, add_middleware
from .routes import admin, public


def create_app() -> FastAPI:
    app = FastAPI(title="Vicbless", docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(public.router, prefix="/api")
    app.include_router(admin.login_router, prefix="/api/admin")
    app.include_router(admin.router, prefix="/api/admin")
    add_error_handlers(app)
    add_middleware(app)
    return app


app = create_app()
