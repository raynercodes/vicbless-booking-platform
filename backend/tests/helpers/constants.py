"""Fixed values the tests share, so every test talks about the same "today", password and table."""

from datetime import datetime

from app.domain import shop

# The tests pretend it is Monday 12 Oct 2026, 10:00 am in the shop's timezone. A fixed "now" means a
# test about "tomorrow" or "14 days ahead" gives the same answer next year as it does today.
NOW = datetime(2026, 10, 12, 10, 0, tzinfo=shop.TIMEZONE)

TEST_TABLE = "vicbless-test"
ENVIRONMENT = "dev"

# Dates relative to NOW that the tests use a lot.
MONDAY = "2026-10-12"  # today
TUESDAY = "2026-10-13"  # open 12:00 to 6:00 pm
WEDNESDAY = "2026-10-14"  # closed
SATURDAY = "2026-10-17"  # two windows with a lunch gap

# Sign-in secrets. The password hash is made with 1,000 rounds (not 600,000) so each test stays fast.
ADMIN_PASSWORD = "correct horse battery"
PEPPER = "test-pepper-value"
JWT_SECRET = "j" * 40
