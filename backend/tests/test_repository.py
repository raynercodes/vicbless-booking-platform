import threading
from datetime import date

import pytest

from app.core.errors import Conflict, NotFound, SlotTaken
from app.database import blocks as blocks_db
from app.database import bookings as bookings_db
from app.database import login_attempts
from app.database import schedule as schedule_db
from app.domain import shop
from tests.helpers.aws import raw_table
from tests.helpers.builders import make_booking as make
from tests.helpers.builders import taken_blocks as claims

TUE = date(2026, 10, 13)


def test_two_blocks_are_claimed_for_a_70_minute_booking():
    make(minutes=70)
    assert claims() == [720, 755]


def test_overlap_with_a_multi_block_booking_is_refused_and_writes_nothing():
    make(start=720, minutes=70)
    with pytest.raises(SlotTaken):
        make(start=755, phone="5550102222")
    assert claims() == [720, 755]
    bookings, _ = schedule_db.day_schedule(TUE)
    assert len(bookings) == 1


def test_all_or_nothing_when_the_second_block_is_taken():
    make(start=755)
    with pytest.raises(SlotTaken):
        make(start=720, minutes=70, phone="5550102222")
    assert claims() == [755]  # the 12:00 claim was NOT left behind
    assert len(schedule_db.day_schedule(TUE)[0]) == 1


def test_cancel_releases_every_block():
    b = make(minutes=70)
    bookings_db.cancel_booking(b.id)
    assert claims() == []
    make(start=755, phone="5550102222")  # now free


def test_cancel_does_not_touch_other_bookings():
    a = make(start=720)
    make(start=755, phone="5550102222")
    bookings_db.cancel_booking(a.id)
    assert claims() == [755]


def test_cancel_missing_is_not_found():
    with pytest.raises(NotFound):
        bookings_db.cancel_booking("2026-10-13.0720.abcdef12")


def test_items_carry_a_ttl_and_the_sparse_index_keys():
    b = make()
    table = raw_table()
    item = table.get_item(Key={"pk": "STAFF#vic", "sk": f"2026-10-13#BOOKING#1200#{b.id}"})["Item"]
    claim = table.get_item(Key={"pk": "STAFF#vic", "sk": "2026-10-13#CLAIM#1200"})["Item"]
    assert int(item["expiresAt"]) == int(claim["expiresAt"]) > 1_790_000_000
    assert item["gsi1pk"] == "PHONE#5550101234" and "gsi1pk" not in claim


def test_phone_count_only_counts_from_the_given_day():
    make(phone="5550101234")
    make(start=755, phone="5550101234")
    make(start=720, day=date(2026, 10, 15), phone="5550101234")
    assert bookings_db.upcoming_for_phone("5550101234", TUE) == 3
    assert bookings_db.upcoming_for_phone("5550101234", date(2026, 10, 14)) == 1
    assert bookings_db.upcoming_for_phone("5559999999", TUE) == 0


def test_block_and_booking_conflict_both_ways():
    blocks_db.create_block(day=TUE, claims=[720, 755], start=720, end=790, note="", whole=False)
    with pytest.raises(SlotTaken):
        make(start=755)
    b = make(start=790, phone="5550102222")
    with pytest.raises(Conflict):
        blocks_db.create_block(day=TUE, claims=[790], start=790, end=825, note="", whole=False)
    assert b


def test_availability_ranges_do_not_leak_between_days():
    make(day=TUE)
    make(start=660, day=date(2026, 10, 15))
    out = schedule_db.availability(TUE, date(2026, 10, 15), shop.DEFAULT_SETTINGS)
    assert out["2026-10-13"]["busy"] == [720] and out["2026-10-14"]["busy"] == [] and out["2026-10-15"]["busy"] == [660]


def test_concurrent_attempts_only_one_wins(atomic_transactions):
    # Six people try for the same time at the same moment: the database must pick exactly one.
    results = []
    gate = threading.Barrier(6)

    def attempt(i):
        gate.wait()
        try:
            make(phone=f"555010{i:04d}")
            results.append("won")
        except SlotTaken:
            results.append("lost")

    threads = [threading.Thread(target=attempt, args=(i,)) for i in range(6)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results.count("won") == 1 and results.count("lost") == 5
    assert len(schedule_db.day_schedule(TUE)[0]) == 1


def test_stale_availability_cannot_cause_a_double_booking():
    """Simulates two customers who both saw the time as free: only the first write succeeds."""
    assert 720 not in claims()
    make(phone="5550101111")
    with pytest.raises(SlotTaken):
        make(phone="5550102222")


def test_login_counter_expires_by_time():
    for _ in range(5):
        login_attempts.record_login_failure("1.2.3.4", now=1000)
    assert login_attempts.login_locked("1.2.3.4", now=1500)
    assert not login_attempts.login_locked("1.2.3.4", now=1000 + login_attempts.LOGIN_WINDOW_SECONDS + 1)
    assert not login_attempts.login_locked("5.6.7.8", now=1500)
    login_attempts.record_login_failure("1.2.3.4", now=1000 + login_attempts.LOGIN_WINDOW_SECONDS + 5)  # starts a fresh window
    assert not login_attempts.login_locked("1.2.3.4", now=2000 + login_attempts.LOGIN_WINDOW_SECONDS)
