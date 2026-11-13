-- Today vs typical: share of washer-minutes in use, by hour of day (Mountain time), for today
-- against the average of every earlier day on record. Reads only the gold table usage_hourly.
with h as (
  select (hour at time zone 'America/Denver')::date              as day,
         extract(hour from hour at time zone 'America/Denver')::int as hour_of_day,
         sum(n_in_use)::numeric / nullif(sum(n_free + n_in_use), 0) as busy
  from laundry.usage_hourly
  group by 1, 2
), today as (select (now() at time zone 'America/Denver')::date as d)
select hour_of_day,
       round(100 * max(busy) filter (where day = today.d), 1) as today_pct_in_use,
       round(100 * avg(busy) filter (where day < today.d), 1) as typical_pct_in_use,
       count(*) filter (where day < today.d)                  as days_in_typical
from h, today
group by hour_of_day
order by hour_of_day;
