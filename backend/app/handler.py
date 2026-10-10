"""AWS Lambda entry point: API Gateway (HTTP API) -> Mangum -> FastAPI."""

from mangum import Mangum

from .main import app

lambda_handler = Mangum(app, lifespan="off")
