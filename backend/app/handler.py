"""AWS Lambda entry point. Two kinds of events arrive here:

  - web requests from API Gateway (HTTP API) -> Mangum -> FastAPI
  - a scheduled event from EventBridge every 15 minutes -> the reminder sweep (services/reminders.py), and giving back
    the time of online bookings that were never paid (services/payments.py)
"""

from mangum import Mangum

from .core.logs import log
from .main import app
from .domain import shop
from .services import payments, reminders

_web = Mangum(app, lifespan="off")


def lambda_handler(event, context):
    # A scheduled EventBridge event says source "aws.events". Web requests never do.
    if isinstance(event, dict) and event.get("source") == "aws.events":
        log("scheduled_event", kind="reminders")  # proves the 15 minute timer is firing
        result = reminders.send_due()
        result["holdsReleased"] = payments.release_expired(shop.now_local())  # unpaid online bookings whose time ran out
        return result
    return _web(event, context)
