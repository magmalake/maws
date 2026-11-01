"""The AWS side: list what is running, price it, and read the bill.

Two caches live under ``~/.cache/maws`` (shared with the Mojo build, same
format):

* ``prices.json`` — Pricing API answers, kept for 7 days. List prices change
  rarely and there are only a handful of distinct keys per account.
* ``bill.json`` — the last Cost Explorer answer, kept for 1 hour. Every
  ``GetCostAndUsage`` call is billed at $0.01, and the data behind it only
  moves a few times a day, so polling it on every refresh would cost money
  for nothing.
"""

from __future__ import annotations

import json
import os
import time
from datetime import date
from pathlib import Path

import boto3

from .model import (
    PUBLIC_IPV4_HOURLY,
    Bill,
    Resource,
    ServiceCost,
    billing_period,
    ebs_hourly,
    ebs_price_filters,
    ec2_price_filters,
    nat_price_filters,
    on_demand_usd,
    parse_cost_and_usage,
    tag_name,
)

CACHE_DIR = Path(os.environ.get("MAWS_CACHE_DIR", Path.home() / ".cache" / "maws"))
PRICE_TTL = 7 * 24 * 3600
BILL_TTL = 3600


class PriceCache:
    def __init__(self, session: boto3.Session):
        # The Pricing API is only served from a few regions; us-east-1 answers
        # for every region's products.
        self._client = session.client("pricing", region_name="us-east-1")
        self._path = CACHE_DIR / "prices.json"
        try:
            self._data: dict = json.loads(self._path.read_text())
        except (OSError, ValueError):
            self._data = {}

    def lookup(self, key: str, service: str, filters: list[dict], unit: str) -> float | None:
        hit = self._data.get(key)
        if hit and time.time() - hit["at"] < PRICE_TTL:
            return hit["usd"]
        resp = self._client.get_products(ServiceCode=service, Filters=filters, MaxResults=10)
        usd = None
        for item in resp.get("PriceList", []):
            usd = on_demand_usd(item, unit)
            if usd is not None:
                break
        self._data[key] = {"usd": usd, "at": time.time()}
        self._save()
        return usd

    def _save(self) -> None:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._data, indent=1, sort_keys=True))
        tmp.replace(self._path)


def list_resources(session: boto3.Session, region: str, prices: PriceCache) -> list[Resource]:
    ec2 = session.client("ec2", region_name=region)
    out: list[Resource] = []

    eip_ips = set()
    for addr in ec2.describe_addresses().get("Addresses", []):
        eip_ips.add(addr.get("PublicIp"))
        attached = "AssociationId" in addr
        out.append(
            Resource(
                "eip",
                region,
                addr.get("AllocationId", addr.get("PublicIp", "")),
                tag_name(addr.get("Tags")),
                addr.get("PublicIp", ""),
                "attached" if attached else "idle",
                PUBLIC_IPV4_HOURLY,
            )
        )

    for page in ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["pending", "running"]}]
    ):
        for res in page["Reservations"]:
            for inst in res["Instances"]:
                itype = inst["InstanceType"]
                hourly = prices.lookup(
                    f"ec2/{region}/{itype}", "AmazonEC2", ec2_price_filters(region, itype), "Hrs"
                )
                note = ""
                if inst.get("InstanceLifecycle") == "spot":
                    note = "spot: on-demand price shown"
                if inst.get("Platform") == "windows":
                    note = "windows: Linux price shown"
                pub = inst.get("PublicIpAddress")
                if pub and pub not in eip_ips and hourly is not None:
                    hourly += PUBLIC_IPV4_HOURLY
                    note = (note + "; " if note else "") + "+public IPv4"
                out.append(
                    Resource(
                        "ec2",
                        region,
                        inst["InstanceId"],
                        tag_name(inst.get("Tags")),
                        itype,
                        inst["State"]["Name"],
                        hourly,
                        note,
                    )
                )

    for page in ec2.get_paginator("describe_volumes").paginate():
        for vol in page["Volumes"]:
            vtype = vol["VolumeType"]
            gb_mo = prices.lookup(
                f"ebs/{region}/{vtype}", "AmazonEC2", ebs_price_filters(region, vtype), "GB-Mo"
            )
            hourly = None if gb_mo is None else ebs_hourly(gb_mo, vol["Size"])
            out.append(
                Resource(
                    "ebs",
                    region,
                    vol["VolumeId"],
                    tag_name(vol.get("Tags")),
                    f"{vtype} {vol['Size']} GiB",
                    vol["State"],
                    hourly,
                    "storage only (no IOPS/throughput)" if vtype in ("io1", "io2", "gp3") else "",
                )
            )

    for page in ec2.get_paginator("describe_nat_gateways").paginate(
        Filter=[{"Name": "state", "Values": ["pending", "available"]}]
    ):
        for nat in page["NatGateways"]:
            hourly = prices.lookup(f"nat/{region}", "AmazonEC2", nat_price_filters(region), "Hrs")
            out.append(
                Resource(
                    "nat",
                    region,
                    nat["NatGatewayId"],
                    tag_name(nat.get("Tags")),
                    nat.get("ConnectivityType", "public"),
                    nat["State"],
                    hourly,
                    "hourly only (no data processing)",
                )
            )
    return out


def month_to_date(session: boto3.Session, today: date | None = None, force: bool = False) -> Bill:
    path = CACHE_DIR / "bill.json"
    if not force:
        try:
            cached = json.loads(path.read_text())
            if time.time() - cached["at"] < BILL_TTL:
                b = cached["bill"]
                return Bill(
                    b["month_to_date"],
                    b["currency"],
                    [ServiceCost(s["service"], s["amount"]) for s in b["by_service"]],
                    b["start"],
                    b["end"],
                )
        except (OSError, ValueError, KeyError):
            pass
    start, end = billing_period(today or date.today())
    ce = session.client("ce", region_name="us-east-1")
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
        bill = parse_cost_and_usage(resp)
    except ce.exceptions.DataUnavailableException:
        # Early on the 1st the month has no ingested data yet: that is a
        # $0.00 month so far, not a failure.
        bill = Bill(0.0, "USD", [], start, end)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "at": time.time(),
                "bill": {
                    "month_to_date": bill.month_to_date,
                    "currency": bill.currency,
                    "by_service": [{"service": s.service, "amount": s.amount} for s in bill.by_service],
                    "start": bill.start,
                    "end": bill.end,
                },
            }
        )
    )
    return bill
