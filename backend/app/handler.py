"""AWS Lambda entry point. Two kinds of events arrive here:

  - web requests from API Gateway (HTTP API) -> Mangum -> FastAPI
  - a scheduled event from EventBridge every 15 minutes -> the reminder sweep (services/reminders.py)
"""

from mangum import Mangum

from .main import app
from .services import reminders

_web = Mangum(app, lifespan="off")


def lambda_handler(event, context):
    # A scheduled EventBridge event says source "aws.events". Web requests never do.
    if isinstance(event, dict) and event.get("source") == "aws.events":
        return reminders.send_due()
    return _web(event, context)
