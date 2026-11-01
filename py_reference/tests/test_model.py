"""The pure half of the reference — the same cases the Mojo tests assert."""

import json
from datetime import date, datetime, timezone

from maws_ref.model import (
    Bill,
    Resource,
    billing_period,
    ebs_hourly,
    hours_left_in_month,
    on_demand_usd,
    parse_cost_and_usage,
    projected_month,
    tag_name,
    total_hourly,
)

EC2_PRICE = json.dumps(
    {
        "product": {"attributes": {"instanceType": "t3.micro"}},
        "terms": {
            "OnDemand": {
                "X.JRTCKXETXF": {
                    "priceDimensions": {
                        "X.JRTCKXETXF.6YS6EN2CT7": {
                            "unit": "Hrs",
                            "pricePerUnit": {"USD": "0.0104000000"},
                        }
                    }
                }
            }
        },
    }
)

TIERED = {
    "terms": {
        "OnDemand": {
            "o": {
                "priceDimensions": {
                    "free": {"unit": "GB-Mo", "pricePerUnit": {"USD": "0.0000000000"}},
                    "paid": {"unit": "GB-Mo", "pricePerUnit": {"USD": "0.0800000000"}},
                    "other": {"unit": "Hrs", "pricePerUnit": {"USD": "1.0"}},
                }
            }
        }
    }
}


def test_on_demand_usd():
    assert on_demand_usd(EC2_PRICE, "Hrs") == 0.0104
    assert on_demand_usd(EC2_PRICE, "GB-Mo") is None
    assert on_demand_usd(TIERED, "GB-Mo") == 0.08
    assert on_demand_usd({"terms": {}}) is None


def test_ebs_hourly():
    assert abs(ebs_hourly(0.08, 100) - 0.010958904) < 1e-9


def test_billing_period():
    assert billing_period(date(2026, 11, 17)) == ("2026-11-01", "2026-11-18")
    assert billing_period(date(2026, 11, 1)) == ("2026-11-01", "2026-11-02")
    assert billing_period(date(2026, 12, 31)) == ("2026-12-01", "2027-01-01")


def test_hours_left_in_month():
    assert hours_left_in_month(datetime(2026, 11, 30, 12, tzinfo=timezone.utc)) == 12.0
    assert hours_left_in_month(datetime(2026, 2, 1, tzinfo=timezone.utc)) == 28 * 24


def test_parse_cost_and_usage_and_projection():
    resp = {
        "ResultsByTime": [
            {
                "TimePeriod": {"Start": "2026-11-01", "End": "2026-11-18"},
                "Groups": [
                    {"Keys": ["Amazon Elastic Compute Cloud - Compute"], "Metrics": {"UnblendedCost": {"Amount": "12.5", "Unit": "USD"}}},
                    {"Keys": ["Tax"], "Metrics": {"UnblendedCost": {"Amount": "0.001", "Unit": "USD"}}},
                    {"Keys": ["Amazon Simple Storage Service"], "Metrics": {"UnblendedCost": {"Amount": "20", "Unit": "USD"}}},
                ],
            }
        ]
    }
    bill = parse_cost_and_usage(resp)
    assert abs(bill.month_to_date - 32.501) < 1e-9
    assert [s.service for s in bill.by_service] == ["Amazon Simple Storage Service", "Amazon Elastic Compute Cloud - Compute"]
    assert (bill.start, bill.end) == ("2026-11-01", "2026-11-18")

    rs = [Resource("ec2", "us-east-1", "i-1", "", "t3.micro", "running", 0.5), Resource("ebs", "us-east-1", "v", "", "", "", None)]
    assert total_hourly(rs) == 0.5
    now = datetime(2026, 11, 30, 12, tzinfo=timezone.utc)
    assert projected_month(Bill(10.0, "USD"), 0.5, now) == 16.0
    assert projected_month(None, 0.5, now) is None


def test_tag_name():
    assert tag_name([{"Key": "env", "Value": "x"}, {"Key": "Name", "Value": "web"}]) == "web"
    assert tag_name(None) == ""
