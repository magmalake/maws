"""The data model and the pure cost arithmetic — no AWS calls here.

Everything in this module is deterministic so it can be unit-tested and, more
importantly, so the Mojo port in ``src/maws`` has an exact behaviour to match:
the same price-list parsing, the same hourly rates, the same projection.
"""

from __future__ import annotations

import calendar
import json
from dataclasses import dataclass, field
from datetime import date, datetime, timezone

HOURS_PER_MONTH = 730.0
"""AWS's own convention for turning a monthly (GB-Mo) rate into an hourly one."""

PUBLIC_IPV4_HOURLY = 0.005
"""Every public IPv4 address — attached or idle — since 2024-02-01. Same price
in every commercial region, so it is a constant rather than a Pricing lookup."""


@dataclass
class Resource:
    kind: str  # "ec2", "ebs", "nat", "eip"
    region: str
    id: str
    name: str
    detail: str  # instance type, "gp3 100 GiB", …
    state: str
    hourly: float | None = None  # None = price unknown
    note: str = ""


@dataclass
class ServiceCost:
    service: str
    amount: float


@dataclass
class Bill:
    month_to_date: float
    currency: str
    by_service: list[ServiceCost] = field(default_factory=list)
    start: str = ""
    end: str = ""


# ---------------------------------------------------------------------------
# Price list parsing
# ---------------------------------------------------------------------------


def on_demand_usd(price_item: str | dict, unit: str | None = None) -> float | None:
    """The on-demand USD price from one Pricing ``GetProducts`` PriceList entry.

    Each entry is a JSON *string* holding ``terms.OnDemand.<offer>
    .priceDimensions.<dim>.pricePerUnit.USD``. When ``unit`` is given only a
    dimension with that unit counts (``Hrs``, ``GB-Mo``); otherwise the first
    non-zero dimension wins — tiered products list a ``0.0`` free tier first.
    """
    item = json.loads(price_item) if isinstance(price_item, str) else price_item
    on_demand = item.get("terms", {}).get("OnDemand", {})
    for offer in on_demand.values():
        for dim in offer.get("priceDimensions", {}).values():
            if unit is not None and dim.get("unit") != unit:
                continue
            usd = dim.get("pricePerUnit", {}).get("USD")
            if usd is None:
                continue
            value = float(usd)
            if value > 0.0:
                return value
    return None


def ec2_price_filters(region: str, instance_type: str) -> list[dict]:
    """Pricing filters that select exactly one product: Linux, shared tenancy,
    no pre-installed software, on-demand capacity."""
    return _filters(
        regionCode=region,
        instanceType=instance_type,
        operatingSystem="Linux",
        tenancy="Shared",
        preInstalledSw="NA",
        capacitystatus="Used",
        licenseModel="No License required",
    )


def ebs_price_filters(region: str, volume_type: str) -> list[dict]:
    return _filters(regionCode=region, productFamily="Storage", volumeApiName=volume_type)


def nat_price_filters(region: str) -> list[dict]:
    return _filters(regionCode=region, productFamily="NAT Gateway")


def _filters(**kv: str) -> list[dict]:
    return [{"Type": "TERM_MATCH", "Field": k, "Value": v} for k, v in kv.items()]


# ---------------------------------------------------------------------------
# Rates and projection
# ---------------------------------------------------------------------------


def ebs_hourly(gb_month_price: float, size_gib: int) -> float:
    return gb_month_price * size_gib / HOURS_PER_MONTH


def total_hourly(resources: list[Resource]) -> float:
    return sum(r.hourly for r in resources if r.hourly is not None)


def hours_left_in_month(now: datetime) -> float:
    """Hours from ``now`` (UTC) to the start of next month."""
    now = now.astimezone(timezone.utc)
    days = calendar.monthrange(now.year, now.month)[1]
    end = datetime(now.year, now.month, days, tzinfo=timezone.utc).timestamp() + 86400
    return max(0.0, (end - now.timestamp()) / 3600.0)


def projected_month(bill: Bill | None, hourly: float, now: datetime) -> float | None:
    """Month-to-date plus the current burn rate for the rest of the month.

    A naive projection — it assumes what is running now keeps running, and
    ignores usage-priced services (S3, data transfer) that only show up in the
    bill. That is the honest reading of "if nothing changes".
    """
    if bill is None:
        return None
    return bill.month_to_date + hourly * hours_left_in_month(now)


def billing_period(today: date) -> tuple[str, str]:
    """Cost Explorer's ``[start, end)`` for month-to-date.

    ``End`` is exclusive and must be after ``Start``, so on the 1st the period
    is the single day ``[today, tomorrow)``.
    """
    start = today.replace(day=1)
    end = date.fromordinal(today.toordinal() + 1)
    return start.isoformat(), end.isoformat()


def parse_cost_and_usage(resp: dict) -> Bill:
    """``GetCostAndUsage`` (MONTHLY, grouped by SERVICE) → a ``Bill``."""
    total = 0.0
    currency = "USD"
    by_service: dict[str, float] = {}
    period = resp.get("ResultsByTime", [])
    for result in period:
        for group in result.get("Groups", []):
            metric = group["Metrics"]["UnblendedCost"]
            amount = float(metric["Amount"])
            currency = metric.get("Unit", currency)
            name = group["Keys"][0]
            by_service[name] = by_service.get(name, 0.0) + amount
            total += amount
    services = sorted(
        (ServiceCost(k, v) for k, v in by_service.items() if abs(v) >= 0.005),
        key=lambda s: s.amount,
        reverse=True,
    )
    start = period[0]["TimePeriod"]["Start"] if period else ""
    end = period[-1]["TimePeriod"]["End"] if period else ""
    return Bill(total, currency, services, start, end)


def tag_name(tags: list[dict] | None) -> str:
    for t in tags or []:
        if t.get("Key") == "Name":
            return t.get("Value", "")
    return ""
