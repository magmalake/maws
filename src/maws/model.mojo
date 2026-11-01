"""`maws.model` — the data model and the pure cost arithmetic.

A line-for-line port of `py_reference/src/maws_ref/model.py`; the tests in
`tests/maws_test.mojo` assert the same cases as `py_reference/tests`.
"""

from .jsonlite import JsonDoc, J_OBJECT, NONE

comptime HOURS_PER_MONTH = 730.0
"""AWS's own convention for turning a monthly (GB-Mo) rate into an hourly one."""

comptime PUBLIC_IPV4_HOURLY = 0.005
"""Every public IPv4 address, attached or idle, since 2024-02-01."""


@fieldwise_init
struct Resource(Copyable, Movable):
    var kind: String
    var region: String
    var id: String
    var name: String
    var detail: String
    var state: String
    var hourly: Float64
    var priced: Bool
    """False when no price was found; `hourly` is then meaningless."""
    var note: String


@fieldwise_init
struct ServiceCost(Copyable, Movable):
    var service: String
    var amount: Float64


@fieldwise_init
struct Bill(Copyable, Movable):
    var month_to_date: Float64
    var currency: String
    var by_service: List[ServiceCost]
    var start: String
    var end: String


# ---------------------------------------------------------------------------
# Price list parsing
# ---------------------------------------------------------------------------


def on_demand_usd(doc: JsonDoc, item: Int, unit: String) -> Optional[Float64]:
    """The on-demand USD price from one parsed `PriceList` entry.

    Only a dimension whose unit is `unit` counts (empty = any), and the first
    non-zero one wins: tiered products list a `0.0` free tier first.
    """
    var on_demand = doc.path(item, "terms/OnDemand")
    for offer in doc.children(on_demand):
        for dim in doc.children(doc.get(offer, "priceDimensions")):
            if unit != "" and doc.str(dim, "unit") != unit:
                continue
            var usd = doc.path(dim, "pricePerUnit/USD")
            if usd == NONE:
                continue
            var v = doc.num(usd)
            if v > 0.0:
                return v
    return None


def on_demand_usd(price_item: String, unit: String) -> Optional[Float64]:
    """Same, from the JSON *string* GetProducts puts in each PriceList slot."""
    try:
        var doc = JsonDoc.parse(price_item)
        return on_demand_usd(doc, doc.root(), unit)
    except:
        return None


def _filter(field: String, value: String) -> String:
    return (
        '{"Type":"TERM_MATCH","Field":"' + field + '","Value":"' + value + '"}'
    )


def ec2_price_filters(region: String, instance_type: String) -> String:
    """A JSON array selecting exactly one product: Linux, shared tenancy, no
    pre-installed software, on-demand capacity."""
    return (
        "["
        + _filter("regionCode", region)
        + ","
        + _filter("instanceType", instance_type)
        + ","
        + _filter("operatingSystem", "Linux")
        + ","
        + _filter("tenancy", "Shared")
        + ","
        + _filter("preInstalledSw", "NA")
        + ","
        + _filter("capacitystatus", "Used")
        + ","
        + _filter("licenseModel", "No License required")
        + "]"
    )


def ebs_price_filters(region: String, volume_type: String) -> String:
    return (
        "["
        + _filter("regionCode", region)
        + ","
        + _filter("productFamily", "Storage")
        + ","
        + _filter("volumeApiName", volume_type)
        + "]"
    )


def nat_price_filters(region: String) -> String:
    return (
        "["
        + _filter("regionCode", region)
        + ","
        + _filter("productFamily", "NAT Gateway")
        + "]"
    )


# ---------------------------------------------------------------------------
# Rates, calendar and projection
# ---------------------------------------------------------------------------


def ebs_hourly(gb_month_price: Float64, size_gib: Int) -> Float64:
    return gb_month_price * Float64(size_gib) / HOURS_PER_MONTH


def total_hourly(resources: List[Resource]) -> Float64:
    var t = 0.0
    for k in range(len(resources)):
        if resources[k].priced:
            t += resources[k].hourly
    return t


def unpriced_count(resources: List[Resource]) -> Int:
    var n = 0
    for k in range(len(resources)):
        if not resources[k].priced:
            n += 1
    return n


def is_leap(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


def days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def days_from_civil(y_: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 (Howard Hinnant's algorithm)."""
    var y = y_ - 1 if m <= 2 else y_
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


@fieldwise_init
struct Civil(Copyable, Movable):
    var year: Int
    var month: Int
    var day: Int


def civil_from_days(z_: Int) -> Civil:
    var z = z_ + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    return Civil(y + 1 if m <= 2 else y, m, d)


def _pad2(v: Int) -> String:
    return ("0" if v < 10 else "") + String(v)


def iso_date(c: Civil) -> String:
    return String(c.year) + "-" + _pad2(c.month) + "-" + _pad2(c.day)


def hours_left_in_month(epoch: Int) -> Float64:
    """Hours from `epoch` (UTC seconds) to the start of next month."""
    var today = civil_from_days(epoch // 86400)
    var end_day = days_from_civil(today.year, today.month, 1) + days_in_month(
        today.year, today.month
    )
    var left = Float64(end_day * 86400 - epoch) / 3600.0
    return left if left > 0.0 else 0.0


def projected_month(
    bill: Optional[Bill], hourly: Float64, epoch: Int
) -> Optional[Float64]:
    """Month-to-date plus the current burn for the rest of the month."""
    if not bill:
        return None
    return bill.value().month_to_date + hourly * hours_left_in_month(epoch)


def billing_period(epoch: Int) -> Tuple[String, String]:
    """Cost Explorer's `[start, end)` for month-to-date; on the 1st it is
    the single day `[today, tomorrow)`."""
    var days = epoch // 86400
    var today = civil_from_days(days)
    var start = Civil(today.year, today.month, 1)
    return Tuple(iso_date(start), iso_date(civil_from_days(days + 1)))


def parse_cost_and_usage(body: String) raises -> Bill:
    """`GetCostAndUsage` (MONTHLY, grouped by SERVICE) → a `Bill`."""
    var doc = JsonDoc.parse(body)
    var results = doc.get(doc.root(), "ResultsByTime")
    var names = List[String]()
    var amounts = List[Float64]()
    var total = 0.0
    var currency = String("USD")
    var periods = doc.children(results)
    for r in periods:
        for g in doc.children(doc.get(r, "Groups")):
            var metric = doc.path(g, "Metrics/UnblendedCost")
            var amount = doc.num(doc.get(metric, "Amount"))
            var unit = doc.str(metric, "Unit")
            if unit != "":
                currency = unit
            var name = doc.text(doc.path(g, "Keys/0"))
            var found = -1
            for k in range(len(names)):
                if names[k] == name:
                    found = k
                    break
            if found >= 0:
                amounts[found] += amount
            else:
                names.append(name)
                amounts.append(amount)
            total += amount

    var services = List[ServiceCost]()
    for k in range(len(names)):
        if abs(amounts[k]) >= 0.005:
            services.append(ServiceCost(names[k], amounts[k]))
    # Largest first; insertion sort, the list is a few dozen services.
    for i in range(1, len(services)):
        var cur = services[i].copy()
        var j = i - 1
        while j >= 0 and services[j].amount < cur.amount:
            services[j + 1] = services[j].copy()
            j -= 1
        services[j + 1] = cur^

    var start = String("")
    var end = String("")
    if len(periods) > 0:
        start = doc.text(doc.path(periods[0], "TimePeriod/Start"))
        end = doc.text(doc.path(periods[len(periods) - 1], "TimePeriod/End"))
    return Bill(total, currency, services^, start, end)


def sort_by_hourly(mut resources: List[Resource]):
    """Most expensive first; unpriced ones sink to the bottom."""
    for i in range(1, len(resources)):
        var cur = resources[i].copy()
        var key = cur.hourly if cur.priced else -1.0
        var j = i - 1
        while j >= 0:
            var kj = resources[j].hourly if resources[j].priced else -1.0
            if kj >= key:
                break
            resources[j + 1] = resources[j].copy()
            j -= 1
        resources[j + 1] = cur^
