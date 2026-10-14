"""Who the shop is, in one place: the name, address and contact email that customers see.

Used by the emails (their branded footer) and by the error messages that tell a customer how to reach Vic.
Kept in core/ with no imports, so anything can use it. The site has its own copy in frontend/src/config.js,
and a test checks the two match.
"""

from __future__ import annotations

BRAND_NAME = "VICBLESS BARBERSHOP"
BRAND_TAGLINE = "Every cut isn't just a cut. It's a blessing."
CONTACT_EMAIL = "vicslegacy89@gmail.com"
ADDRESS_LINES: tuple[str, ...] = ("656 S Main St, Suite C", "Baxley, GA 31513")
