# CS6302 Lab Activity 2

Roll number: 2026204015


---

## Assumptions

**1. Database name.** Everything lives in `fooddelivery_2026204015`.

**2. The staging table is just a copy of the CSV.** Same six columns, nothing
cleaned or removed. The only thing I added is `EventID`, an auto-increment id.
Since `LOAD DATA` inserts rows in file order, `EventID` also remembers the
original order of the file, which turned out to be useful (see assumption 3).

**3. Events inside an order are sorted by `Timestamp`, then `EventID`.** I sort
by timestamp first, and if two events of the same order somehow share a
timestamp I fall back to `EventID` to break the tie. Without that fallback the
time metrics could come out differently on different runs, which I didn't want.

**4. How I handle dropped-and-reassigned orders (the main decision).**
I split each order into *assignment attempts*. An attempt is one
`PendingAssignment` plus every event after it until the next `PendingAssignment`.
Every event in an attempt belongs to whichever partner accepted that attempt.

So for `ORD-8` above, the first attempt including its `Dropped` goes to PRT-189,
and the second attempt including the `Delivered` goes to PRT-129.

I thought about the two obvious alternatives and didn't like either. If I gave
the whole order to the **final** partner, then PRT-129 would get a `Dropped`
counted against them for something PRT-189 did. If I gave it to the **first**
partner, then PRT-189 would get credit for a delivery they had nothing to do
with. Splitting by attempt was the only version where each partner's row is
actually about what that partner did, which seemed like the point of the table.
The downside is that a re-assigned order shows up under two partners, which I've
noted in assumption 9.

**5. The blank `PartnerID` gets filled in.** On `PendingAssignment` rows
`PartnerID` is an empty string rather than NULL, so I declared the column
`NOT NULL DEFAULT ''`. I don't treat `''` as a real partner — those rows get
attributed to whoever accepted that attempt, so `TotalPendingAssignment` ends up
on the accepting partner instead of in a junk empty-string row. In this dataset
every attempt does get accepted, so no empty rows appear at all (I checked, it's
zero). If an attempt never got accepted its events would collect under `''`.

**6. Month and year always come from the order's *first* `PendingAssignment`.**
The question says to do this, and I apply it to *all* of an order's events,
including the second attempt. So if an order is placed at 23:58 on 31 March and
re-assigned at 00:03 on 1 April, both attempts still count as March. Otherwise
one order would get split across two months, which felt wrong.

Also, since PIN code never changes within an order, both attempts share the same
PIN too.

**7. Time differences are in whole minutes.** I used `TIMESTAMPDIFF(MINUTE, ...)`
as asked. It chops off the seconds rather than rounding, so a gap of 4 minutes
25 seconds counts as 4. Each order's value is a whole number and only the
average stored in the table has decimals.

**8. Three of the four time metrics are per attempt, one is per order.**

| Metric | From → to | Measured over |
|---|---|---|
| `TimetoAccept` | that attempt's `PendingAssignment` → its `Accepted` | one attempt |
| `TimetoPickup` | that attempt's `Accepted` → its `PickedUp` | one attempt |
| `TimetoArriveatDoorStep` | that attempt's `PickedUp` → its `ArrivedatDoorStep` | one attempt |
| `TimetoDeliver` | the order's **first** `PendingAssignment` → `Delivered` | whole order |

`TimetoDeliver` is defined in the question as starting from the first
`PendingAssignment`, so for a re-assigned order it includes all the time wasted
on the failed first attempt, and that whole thing lands on the partner who
finally delivered. That's a bit unfair on the second partner, but it's what was
asked for so I did it that way instead of changing the definition. It's also the
number the customer actually experiences, which is why I reused the same
definition for `AvgTimeToDeliver` in the requestor table.

**9. `TotalOrders` counts distinct order ids, so it doesn't add up to 100,000.**
This follows from assumption 4. If you add `TotalOrders` across every row you get
109,892, not 100,000, because re-assigned orders appear under two partners. The
number isn't 109,921 either, because 29 orders happened to be re-offered to the
*same* partner twice, and `COUNT(DISTINCT OrderID)` correctly counts those once.
So this column is a per-row count and shouldn't be summed up.

**10. Empty milestones are left as NULL, not 0.** `AVG()` skips NULLs, so
`TimetoPickup` is averaged only over attempts that actually reached `PickedUp`.
If nothing in a row ever got that far the column stays NULL. I didn't want to
put 0 there because 0 would look like it happened instantly.

**11. For `requestorstatistics_2026204015` I used one row per requestor per month.**
Same monthly level as the delivery table so the two can be lined up against each
other. That gives 23,633 rows. One row per requestor for all time would have been
easier but then you can't see anything change month to month.

An order counts as delivered / cancelled / failed / returned if it has that
event in it. The rates are percentages out of the orders placed that month, so a
customer with 3 orders and one with 20 can still be compared. Ties for
"most used PIN" and "most frequent partner" are broken by the smaller id, just so
the answer is the same every time I run it.

**12. Both procedures truncate their table first so they can be re-run.** I went
with truncate-and-rebuild rather than updating rows in place, because these are
totals over the whole history and an update would leave old rows sitting there
that no longer belong. I ran both twice in a row to check, and the second run
gives exactly the same rows as the first.

---

## Task 2 — how `PopulateDeliveryStatistics_2026204015()` works

It goes in five steps:

1. A `GROUP BY` to get one row per order with its PIN and its placement
   month/year (assumption 6).
2. **The cursor.** This walks the events in order and works out the attempts and
   the four time metrics.
3. A window function to tag every event row with which attempt it belongs to.
4. A `GROUP BY` for the 14 status counts.
5. An `UPDATE ... JOIN` to write the four averages onto the rows.

The cursor is the part the question asks for, so that's where the sequence-based
work happens. It has the `DECLARE ... CURSOR FOR`, the
`DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1`, and a
`LOOP / FETCH / LEAVE`. As it walks through it keeps a few variables around —
the order's first `PendingAssignment`, the current attempt's `PendingAssignment`,
and the `Accepted` and `PickedUp` times. When it hits a `PendingAssignment` it
closes off the attempt it was building, writes one row for it, and starts a new
one. The last attempt gets written when the handler fires at the end.

Two things I did to stop it being unbearably slow:

- the cursor only selects the five statuses it actually needs (494,587 rows out
  of 829,801) — the other statuses don't mark the start or end of anything
- it writes one row per attempt (about 110,000 inserts) instead of running a
  statement for every single event

Step 3 works out the attempt number by keeping a running count of how many
`PendingAssignment` rows have been seen so far in that order:

```sql
SUM(CASE WHEN Status = 'PendingAssignment' THEN 1 ELSE 0 END)
    OVER (PARTITION BY OrderID ORDER BY `Timestamp`, EventID
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
```

Joining that back to the cursor's output on `(OrderID, AttemptNo)` gives every
event the right partner, and then the counts are just one `GROUP BY`.

---

## Task 3: KPIs

The delivery table tells you which partner or area is doing badly. I wanted this
one to answer the other side of it: which customer is having a bad time, and is
it bad enough that they'd stop ordering. So I picked things you could actually
do something about.

| KPI | Why it's useful |
|---|---|
| `TotalOrdersPlaced` | How much this customer orders. Also what all the rates are divided by, and it tells you whether a bad rate is real or just two orders. |
| `TotalDelivered` | How many times it actually worked. |
| `TotalCancelled` | Cancellations as a plain count, since that's refund work for someone. |
| `TotalDeliveryFailed` | Worse than a cancellation — the food was cooked and picked up and then lost, so it costs real money. |
| `TotalReturned` | Confirms the failed order actually came back to the store, so the loss can be checked against returned stock. |
| `TotalReassigned` | Orders that needed a second partner. Someone quietly putting up with this a lot is likely to stop ordering before they ever complain. |
| `CancellationRate` | The same thing as a percentage so customers of different sizes can be compared. Usually means a bad address or a hard-to-serve area rather than a difficult customer. |
| `FailureRate` | The clearest "are we letting this person down" number, and a decent trigger for giving them a refund before they ask. |
| `FulfilmentRate` | The positive version, and the one worth putting on a dashboard since it's what the customer thinks of as reliability. |
| `ReassignmentRate` | Helps tell an area problem from a partner problem — lots of partners dropping the same PIN means the area is the issue. |
| `AvgTimeToAccept` | How long the customer sits looking at "finding a partner". If it's high there probably aren't enough partners near them at that time. |
| `AvgTimeToDeliver` | The main promise. Compare it against the target time to see if this customer is consistently getting a worse deal. |
| `WorstTimeToDeliver` | Averages hide the disasters. One 95-minute delivery causes a complaint; a slightly high average doesn't. |
| `MostUsedPIN` and `DistinctPINsUsed` | Where they actually order to. `MostUsedPIN` lets you trace a bad experience back to a bad area, and links straight back to `deliverystatistics_2026204015`. |
| `MostFrequentPartnerID` and `DistinctPartnersUsed` | If all of one customer's problems come from one partner that's a partner problem; if they're spread over 14 partners it's the area or the address. |
| `FirstOrderTimestamp` / `LastOrderTimestamp` | Rough idea of when they were active that month, and an easy way to spot someone who's stopped ordering. |

I wrote `PopulateRequestorStatistics_2026204015()` without a cursor on purpose, using window
functions instead, so that the two procedures make a fair comparison for the next
question.

---

## Task 4 — cursor vs set-based

The metric I'll take is `TimetoAccept`. It can definitely be done without a
cursor, and I actually wrote it both ways to make sure:
`MAX(CASE WHEN Status = 'PendingAssignment' THEN Timestamp END) OVER (PARTITION BY
OrderID ORDER BY Timestamp, EventID ROWS UNBOUNDED PRECEDING)` carries the
current attempt's assignment time down onto the `Accepted` row, and then one
`TIMESTAMPDIFF` gives the same answer the cursor works out row by row — that's
what step 2 of `PopulateRequestorStatistics_2026204015()` does, and both versions return the
same 109,921 pairs with the same 3.00 minute average. What you gain by dropping
the cursor is speed and less code: the window version took about 2.8 seconds
against roughly 12 seconds for the cursor pass, because MySQL sorts each order's
rows once and streams through them instead of going back and forth through the
stored-procedure interpreter for half a million fetches. What you lose is the
shared state — the cursor gets all four time metrics out of one walk through the
data because the first `PendingAssignment`, the `Accepted` time and the
`PickedUp` time are all sitting in variables at the same moment, whereas the
window version needs a separate expression and effectively a separate pass for
each metric, and the "an attempt ends at the next `PendingAssignment`" rule has
to be written out again in every one of them. So for any single metric the
set-based version wins easily, and the cursor is only really worth it when one
pass has to keep track of several things at once — which is why I used the cursor
in Task 2 and window functions in Task 3.

---

## Checks I ran

I ran these on the full dataset after both procedures finished:

- 829,801 rows loaded and 100,000 orders, which matches the question
- all 14 status counts in `deliverystatistics_2026204015` match the counts straight off the
  event log
- adding up all 14 count columns gives 829,801, the same as the number of rows in
  staging, so no event is missing or counted twice
- no rows with a blank `PartnerID` (assumption 5)
- the requestor table totals match the raw log too — 100,000 placed, 89,882
  delivered, 5,019 cancelled, 5,099 failed, 9,921 re-assigned
- no NULLs in `MostUsedPIN` or `MostFrequentPartnerID`
- running both procedures a second time gives identical rows

I also worked out `ORD-8` by hand from the CSV and compared:

| Attempt | Partner | TimetoAccept | TimetoPickup | TimetoArriveatDoorStep | TimetoDeliver |
|---|---|---|---|---|---|
| 1 (dropped) | PRT-189 | 4 | NULL | NULL | NULL |
| 2 (delivered) | PRT-129 | 1 | 16 | 11 | 40 |

Both match. PRT-189 keeps its own 4 minute accept and its drop, PRT-129 keeps the
delivery, and PRT-129's 40 minutes is counted from the order's first
`PendingAssignment` at 02:17:09 rather than from its own accept, which is
assumption 8. These are the per-attempt numbers — the actual rows in
`deliverystatistics_2026204015` for those two partners also contain other orders, so they
show averages rather than these exact values.

The overall numbers came out looking sensible for a food delivery app:

| Metric | Min | Average | Max |
|---|---|---|---|
| `TimetoAccept` | 1.00 | 3.00 | 5.00 |
| `TimetoPickup` | 8.00 | 21.22 | 73.00 |
| `TimetoArriveatDoorStep` | — | 20.97 | — |
| `TimetoDeliver` | 22.00 | 48.36 | 104.00 |

---

## Things I know aren't perfect

- `TIMESTAMPDIFF(MINUTE, ...)` throws away the seconds, so every duration is up
  to 59 seconds short. I could have used seconds and divided by 60, but the
  question asked for minutes so I left it.
- `TimetoDeliver` blames the second partner for time wasted by the first one
  (assumption 8). I've written it down rather than quietly changing it.
- The cursor is easily the slowest part of the whole thing.
- Everything is from 2026, so I never actually got to test that `YearofOrder`
  behaves properly across two different years.
