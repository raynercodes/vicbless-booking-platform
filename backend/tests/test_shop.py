from datetime import date, datetime

import pytest

from app.core.errors import InvalidSlot, SlotUnavailable
from app.domain import shop
from tests.helpers.constants import NOW

TUE = date(2026, 10, 13)
WED = date(2026, 10, 14)
SAT = date(2026, 10, 17)
SUN = date(2026, 10, 18)
at = shop.at


def test_weekday_mapping():
    # 2026-10-12 is a Monday; each day of that week
    expected_open = {12: True, 13: True, 14: False, 15: True, 16: True, 17: True, 18: False}
    for day, is_open in expected_open.items():
        assert shop.is_open(date(2026, 10, day)) is is_open


def test_tuesday_grid_runs_from_opening_in_35_minute_steps():
    grid = shop.grid_starts(TUE)
    assert grid[0] == at(12) and grid[1] == at(12, 35)
    assert len(grid) == 10
    assert grid[-1] + 35 <= at(18)


def test_thursday_friday_have_13_blocks():
    assert len(shop.grid_starts(date(2026, 10, 15))) == 13
    assert len(shop.grid_starts(date(2026, 10, 16))) == 13


def test_saturday_has_two_windows_and_a_gap():
    grid = shop.grid_starts(SAT)
    assert grid[0] == at(9) and at(12, 35) in grid
    assert at(12) not in grid
    for s in grid:
        assert (at(9) <= s and s + 35 <= at(12)) or (at(12, 35) <= s and s + 35 <= at(17))


def test_closed_days_have_no_grid():
    assert shop.grid_starts(WED) == [] and shop.grid_starts(SUN) == []


def test_blocks_for():
    assert [shop.blocks_for(m) for m in (30, 35, 36, 70, 71)] == [1, 1, 2, 2, 3]


def test_fits_matches_grid_and_closing():
    assert shop.fits(TUE, at(12), 35)
    assert not shop.fits(TUE, at(12, 10), 35)  # off the grid
    assert not shop.fits(TUE, at(17, 50), 35)  # would run past closing
    assert not shop.fits(WED, at(12), 35)
    assert not shop.fits(SAT, at(12), 35)  # inside Saturday's gap


def test_multi_block_must_stay_inside_one_window():
    assert shop.fits(SAT, at(9), 70)
    assert not shop.fits(SAT, at(11, 20), 70)  # second block would cross noon


@pytest.mark.parametrize(
    "when,start,error",
    [
        (date(2026, 10, 13), at(12), None),
        (date(2026, 10, 14), at(12), InvalidSlot),  # closed Wednesday
        (date(2026, 10, 13), at(12, 5), InvalidSlot),  # off grid
        (date(2026, 10, 10), at(9), SlotUnavailable),  # past Saturday
        (date(2026, 10, 26), at(12), SlotUnavailable),  # 14 days ahead is outside 0..13
        (date(2026, 10, 25), at(12), None),  # last day in the window (a Sunday... closed)
    ],
)
def test_check_bookable(when, start, error):
    if when == date(2026, 10, 25):
        error = InvalidSlot  # Sunday is closed, so structure fails first
    if error is None:
        shop.check_bookable(when, start, 35, NOW)
    else:
        with pytest.raises(error):
            shop.check_bookable(when, start, 35, NOW)


def test_last_bookable_day_is_13_days_out():
    # Monday 2026-10-12 + 13 = Sunday the 25th (closed); Saturday the 24th is inside the window
    shop.check_bookable(date(2026, 10, 24), at(9), 35, NOW)
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 26), at(12), 35, NOW)


def test_lead_time_today():
    now = datetime(2026, 10, 12, 12, 5, tzinfo=shop.TIMEZONE)  # Monday 12:05
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12), 35, now)
    with pytest.raises(SlotUnavailable):
        shop.check_bookable(date(2026, 10, 12), at(12, 35), 35, now)  # 12:35 is exactly now + 30, so too soon
    shop.check_bookable(date(2026, 10, 12), at(13, 10), 35, now)  # 13:10 is fine


def test_today_uses_shop_timezone_not_utc():
    # 11 pm Monday in New York is already Tuesday in UTC; "today" must still be Monday
    late = datetime(2026, 10, 12, 23, 0, tzinfo=shop.TIMEZONE)
    assert shop.today(late) == date(2026, 10, 12)
    utc = late.astimezone(__import__("datetime").timezone.utc)
    assert shop.today(utc) == date(2026, 10, 12)


def test_dst_day_still_gives_normal_minutes():
    # Daylight saving ends 2026-11-01 (a Sunday); Monday after is a normal day
    now = datetime(2026, 11, 2, 9, 0, tzinfo=shop.TIMEZONE)
    shop.check_bookable(date(2026, 11, 2), at(12), 35, now)


def test_block_range_and_whole_day():
    assert shop.block_starts_in_range(TUE, at(12), at(12, 35) + 35) == [at(12), at(12, 35)]
    assert shop.block_starts_in_range(TUE, at(12), at(12)) == []
    with pytest.raises(InvalidSlot):
        shop.check_blockable(WED, NOW)
    with pytest.raises(InvalidSlot):
        shop.check_blockable(date(2026, 10, 9), NOW)
    with pytest.raises(InvalidSlot):
        shop.check_blockable(date(2027, 10, 20), NOW)
    shop.check_blockable(date(2026, 10, 13), NOW)


def test_labels():
    assert shop.label(at(12, 35)) == "12:35 pm"
    assert shop.label(at(9)) == "9:00 am"
    assert shop.hhmm(at(7, 20)) == "0720"
