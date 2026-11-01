"""Test suite for maws — the pure half, asserting the same cases as
`py_reference/tests/test_model.py`, plus the JSON reader, the INI reader and
the request plumbing. `MAWS_LIVE_PROFILE=<profile>` adds one live Pricing
lookup (a free API) through the whole signed-request stack."""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from maws.aws import PriceCache
from maws.client import (
    AwsClient,
    FormParam,
    form_encode,
    json_error_code,
    xml_error,
)
from maws.credentials import ini_value, load_credentials
from maws.jsonlite import J_ARRAY, J_NULL, J_OBJECT, JsonDoc, NONE, json_str
from maws.model import (
    Bill,
    Resource,
    billing_period,
    days_from_civil,
    ebs_hourly,
    ec2_price_filters,
    hours_left_in_month,
    on_demand_usd,
    parse_cost_and_usage,
    projected_month,
    sort_by_hourly,
    total_hourly,
)
from maws.tui import cell, fmt_fixed, usd

comptime EC2_PRICE = """{"product": {"attributes": {"instanceType": "t3.micro"}},
 "terms": {"OnDemand": {"X.JRTCKXETXF": {"priceDimensions": {
   "X.JRTCKXETXF.6YS6EN2CT7": {"unit": "Hrs", "pricePerUnit": {"USD": "0.0104000000"}}}}}}}"""

comptime TIERED = """{"terms": {"OnDemand": {"o": {"priceDimensions": {
  "free": {"unit": "GB-Mo", "pricePerUnit": {"USD": "0.0000000000"}},
  "paid": {"unit": "GB-Mo", "pricePerUnit": {"USD": "0.0800000000"}},
  "other": {"unit": "Hrs", "pricePerUnit": {"USD": "1.0"}}}}}}}"""


def _epoch(y: Int, m: Int, d: Int, h: Int = 0) -> Int:
    return days_from_civil(y, m, d) * 86400 + h * 3600


# ---------------------------------------------------------------------------
# jsonlite
# ---------------------------------------------------------------------------


def test_json_parse_and_lookup() raises:
    var doc = JsonDoc.parse(
        '{"a": {"b": [1, "x\\u00e9\\ud83d\\ude00", 2.5e1, true, null]}, "e":'
        ' {}, "s": "q\\"\\n"}'
    )
    var r = doc.root()
    assert_equal(doc.kind(r), J_OBJECT)
    assert_equal(doc.count(doc.path(r, "a/b")), 5)
    assert_equal(doc.kind(doc.path(r, "a/b")), J_ARRAY)
    assert_equal(doc.text(doc.path(r, "a/b/1")), "xé😀")
    assert_equal(doc.num(doc.path(r, "a/b/2")), 25.0)
    assert_equal(doc.text(doc.path(r, "a/b/3")), "true")
    assert_equal(doc.kind(doc.path(r, "a/b/4")), J_NULL)
    assert_equal(doc.path(r, "a/b/9"), NONE)
    assert_equal(doc.path(r, "nope/x"), NONE)
    assert_equal(doc.count(doc.get(r, "e")), 0)
    assert_equal(doc.str(r, "s"), 'q"\n')


def test_json_errors() raises:
    with assert_raises():
        _ = JsonDoc.parse('{"a": 1,}')
    with assert_raises():
        _ = JsonDoc.parse('{"a": 1} x')
    with assert_raises():
        _ = JsonDoc.parse('"\\ud83d"')
    with assert_raises():
        _ = JsonDoc.parse("[1, 2")


def test_json_str_roundtrip() raises:
    var s = String('a"b\\c\n\t\x01é')
    var doc = JsonDoc.parse("[" + json_str(s) + "]")
    assert_equal(doc.text(doc.at(doc.root(), 0)), s)


# ---------------------------------------------------------------------------
# model — the same cases as py_reference/tests/test_model.py
# ---------------------------------------------------------------------------


def test_on_demand_usd() raises:
    assert_equal(on_demand_usd(String(EC2_PRICE), "Hrs").value(), 0.0104)
    assert_true(not on_demand_usd(String(EC2_PRICE), "GB-Mo"))
    assert_equal(on_demand_usd(String(TIERED), "GB-Mo").value(), 0.08)
    assert_true(not on_demand_usd(String('{"terms": {}}'), ""))


def test_ebs_hourly() raises:
    assert_true(abs(ebs_hourly(0.08, 100) - 0.010958904) < 1e-9)


def test_billing_period() raises:
    var p = billing_period(_epoch(2026, 11, 17, 13))
    assert_equal(p[0], "2026-11-01")
    assert_equal(p[1], "2026-11-18")
    p = billing_period(_epoch(2026, 11, 1))
    assert_equal(p[0], "2026-11-01")
    assert_equal(p[1], "2026-11-02")
    p = billing_period(_epoch(2026, 12, 31, 23))
    assert_equal(p[0], "2026-12-01")
    assert_equal(p[1], "2027-01-01")


def test_hours_left_in_month() raises:
    assert_equal(hours_left_in_month(_epoch(2026, 11, 30, 12)), 12.0)
    assert_equal(hours_left_in_month(_epoch(2026, 2, 1)), Float64(28 * 24))
    assert_equal(hours_left_in_month(_epoch(2028, 2, 1)), Float64(29 * 24))


def test_parse_cost_and_usage_and_projection() raises:
    var body = """{"ResultsByTime": [{"TimePeriod": {"Start": "2026-11-01", "End": "2026-11-18"},
      "Groups": [
        {"Keys": ["Amazon Elastic Compute Cloud - Compute"], "Metrics": {"UnblendedCost": {"Amount": "12.5", "Unit": "USD"}}},
        {"Keys": ["Tax"], "Metrics": {"UnblendedCost": {"Amount": "0.001", "Unit": "USD"}}},
        {"Keys": ["Amazon Simple Storage Service"], "Metrics": {"UnblendedCost": {"Amount": "20", "Unit": "USD"}}}]}]}"""
    var bill = parse_cost_and_usage(body)
    assert_true(abs(bill.month_to_date - 32.501) < 1e-9)
    assert_equal(len(bill.by_service), 2)
    assert_equal(bill.by_service[0].service, "Amazon Simple Storage Service")
    assert_equal(
        bill.by_service[1].service, "Amazon Elastic Compute Cloud - Compute"
    )
    assert_equal(bill.start, "2026-11-01")
    assert_equal(bill.end, "2026-11-18")

    var rs: List[Resource] = [
        Resource("ebs", "us-east-1", "v", "", "", "", 0.0, False, ""),
        Resource(
            "ec2", "us-east-1", "i-1", "", "t3.micro", "running", 0.5, True, ""
        ),
        Resource("eip", "us-east-1", "e", "", "", "", 0.005, True, ""),
    ]
    assert_equal(total_hourly(rs), 0.505)
    sort_by_hourly(rs)
    assert_equal(rs[0].id, "i-1")
    assert_equal(rs[2].id, "v")
    var now = _epoch(2026, 11, 30, 12)
    var b: Optional[Bill] = Bill(10.0, "USD", [], "", "")
    assert_equal(projected_month(b, 0.5, now).value(), 16.0)
    assert_true(not projected_month(None, 0.5, now))


def test_price_filters_are_json() raises:
    var doc = JsonDoc.parse(ec2_price_filters("us-east-2", "t3.micro"))
    assert_equal(doc.count(doc.root()), 7)
    assert_equal(doc.str(doc.at(doc.root(), 1), "Value"), "t3.micro")


# ---------------------------------------------------------------------------
# credentials, client plumbing, formatting
# ---------------------------------------------------------------------------


def test_ini_value() raises:
    var text = String(
        "[default]\nregion = us-east-2\n# c\n[profile dev]\n region=eu-west-1"
        " \naws_access_key_id = AKIA = x\n"
    )
    assert_equal(ini_value(text, "default", "region"), "us-east-2")
    assert_equal(ini_value(text, "profile dev", "region"), "eu-west-1")
    assert_equal(
        ini_value(text, "profile dev", "aws_access_key_id"), "AKIA = x"
    )
    assert_equal(ini_value(text, "missing", "region"), "")


def test_env_credentials_win() raises:
    _ = setenv("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE")
    _ = setenv("AWS_SECRET_ACCESS_KEY", "secret")
    _ = setenv("AWS_SESSION_TOKEN", "tok")
    var c = load_credentials("whatever")
    assert_equal(c.access_key_id, "AKIDEXAMPLE")
    assert_equal(c.session_token, "tok")
    assert_equal(c.source, "env")
    _ = setenv("AWS_ACCESS_KEY_ID", "")
    _ = setenv("AWS_SECRET_ACCESS_KEY", "")
    _ = setenv("AWS_SESSION_TOKEN", "")


def test_form_and_errors() raises:
    var p: List[FormParam] = [
        FormParam("Action", "DescribeInstances"),
        FormParam("Filter.1.Value.1", "a b/c"),
    ]
    assert_equal(
        form_encode(p), "Action=DescribeInstances&Filter.1.Value.1=a%20b%2Fc"
    )
    assert_equal(
        json_error_code('{"__type": "com.amazon#DataUnavailableException"}'),
        "DataUnavailableException",
    )
    var e = xml_error(
        "<Response><Errors><Error><Code>AuthFailure</Code><Message>no</Message>"
        "</Error></Errors></Response>"
    )
    assert_equal(e[0], "AuthFailure")
    assert_equal(e[1], "no")


def test_formatting() raises:
    assert_equal(usd(1234567.891), "$1,234,567.89")
    assert_equal(usd(0.0104, 4), "$0.0104")
    assert_equal(usd(0.0), "$0.00")
    assert_equal(fmt_fixed(-2.5, 1), "-2.5")
    assert_equal(cell("abc", 5), "abc  ")
    assert_equal(cell("abc", 5, True), "  abc")
    assert_equal(cell("abcdef", 4), "abc…")
    assert_equal(cell("éé", 3), "éé ")


def test_live_pricing() raises:
    var profile = getenv("MAWS_LIVE_PROFILE", "")
    if profile == "":
        print("SKIP test_live_pricing: set MAWS_LIVE_PROFILE to run")
        return
    _ = setenv("MAWS_CACHE_DIR", getenv("TMPDIR", "/tmp") + "/maws-test-cache")
    var prices = PriceCache(AwsClient(load_credentials(profile)))
    var p = prices.lookup(
        "ec2/us-east-2/t3.micro-live",
        "AmazonEC2",
        ec2_price_filters("us-east-2", "t3.micro"),
        "Hrs",
    )
    assert_true(Bool(p))
    print("live t3.micro us-east-2:", p.value())
    assert_true(p.value() > 0.001 and p.value() < 1.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
