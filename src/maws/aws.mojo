"""`maws.aws` — list what is running, price it, and read the bill.

The port of `py_reference/src/maws_ref/aws.py`, sharing its caches under
`~/.cache/maws` (`MAWS_CACHE_DIR` overrides): `prices.json` for 7 days and
`bill.json` for 1 hour, because every Cost Explorer call is billed at $0.01.
"""

from std.os import getenv, makedirs
from std.os.path import exists

from sigv4.signer import epoch_now
from xml import Document, NO_NODE

from .client import AwsClient, FormParam
from .jsonlite import J_NULL, JsonDoc, NONE, json_str
from .model import (
    Bill,
    PUBLIC_IPV4_HOURLY,
    Resource,
    ServiceCost,
    billing_period,
    ebs_hourly,
    ebs_price_filters,
    ec2_price_filters,
    nat_price_filters,
    on_demand_usd,
    parse_cost_and_usage,
)

comptime PRICE_TTL = 7 * 24 * 3600
comptime BILL_TTL = 3600


def cache_dir() -> String:
    var d = getenv("MAWS_CACHE_DIR", "")
    if d != "":
        return d
    return getenv("HOME", "") + "/.cache/maws"


def _read(path: String) -> String:
    if not exists(path):
        return String("")
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return String("")


def _write(path: String, text: String) raises:
    var d = cache_dir()
    if not exists(d):
        makedirs(d, exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def fmt_float(v: Float64) -> String:
    """Enough digits to round-trip a price; JSON-safe."""
    return String(v)


@fieldwise_init
struct CachedPrice(Copyable, Movable):
    var key: String
    var usd: Float64
    var known: Bool
    var at: Int


struct PriceCache(Movable):
    var client: AwsClient
    var entries: List[CachedPrice]

    def __init__(out self, client: AwsClient):
        self.client = client.copy()
        self.entries = List[CachedPrice]()
        var text = _read(cache_dir() + "/prices.json")
        if text == "":
            return
        try:
            var doc = JsonDoc.parse(text)
            for e in doc.children(doc.root()):
                var usd = doc.get(e, "usd")
                var known = usd != NONE and doc.kind(usd) != J_NULL
                self.entries.append(
                    CachedPrice(
                        doc.key(e),
                        doc.num(usd),
                        known,
                        Int(doc.num(doc.get(e, "at"))),
                    )
                )
        except:
            pass  # a corrupt cache is just a cold one

    def _save(self) raises:
        var out = String("{\n")
        for k in range(len(self.entries)):
            ref e = self.entries[k]
            out += " " + json_str(e.key) + ': {"at": ' + String(e.at)
            out += ', "usd": ' + (fmt_float(e.usd) if e.known else "null")
            out += "}" + ("," if k + 1 < len(self.entries) else "") + "\n"
        out += "}\n"
        _write(cache_dir() + "/prices.json", out)

    def lookup(
        mut self, key: String, service: String, filters: String, unit: String
    ) raises -> Optional[Float64]:
        var now = epoch_now()
        var slot = -1
        for k in range(len(self.entries)):
            if self.entries[k].key == key:
                slot = k
                if now - self.entries[k].at < PRICE_TTL:
                    if self.entries[k].known:
                        return self.entries[k].usd
                    return None
        var body = (
            '{"ServiceCode":'
            + json_str(service)
            + ',"Filters":'
            + filters
            + ',"MaxResults":10}'
        )
        # The Pricing API is served from us-east-1 for every region.
        var resp = self.client.json_call(
            "api.pricing.us-east-1.amazonaws.com",
            "us-east-1",
            "pricing",
            "AWSPriceListService.GetProducts",
            body,
        )
        var doc = JsonDoc.parse(resp)
        var found: Optional[Float64] = None
        for item in doc.children(doc.get(doc.root(), "PriceList")):
            found = on_demand_usd(doc.text(item), unit)
            if found:
                break
        var entry = CachedPrice(
            key, found.value() if found else 0.0, Bool(found), now
        )
        if slot >= 0:
            self.entries[slot] = entry^
        else:
            self.entries.append(entry^)
        self._save()
        return found


def tag_name(doc: Document, node: Int) -> String:
    for t in doc.find_all(node, "tagSet/item"):
        if doc.child_text(t, "key") == "Name":
            return doc.child_text(t, "value")
    return String("")


def _paged(
    client: AwsClient,
    region: String,
    action: String,
    params: List[FormParam],
) raises -> List[Document]:
    """Every page of a Query operation, following `nextToken`."""
    var pages = List[Document]()
    var token = String("")
    while True:
        var p = params.copy()
        if token != "":
            p.append(FormParam("NextToken", token))
        var doc = client.ec2_call(region, action, p)
        token = doc.child_text(doc.root(), "nextToken")
        pages.append(doc^)
        if token == "":
            return pages^


def list_resources(
    client: AwsClient, region: String, mut prices: PriceCache
) raises -> List[Resource]:
    var out = List[Resource]()

    var eip_ips = List[String]()
    var addrs = client.ec2_call(region, "DescribeAddresses", List[FormParam]())
    for a in addrs.find_all(addrs.root(), "addressesSet/item"):
        var ip = addrs.child_text(a, "publicIp")
        eip_ips.append(ip)
        var attached = addrs.child_text(a, "associationId") != ""
        var id = addrs.child_text(a, "allocationId", ip)
        out.append(
            Resource(
                "eip",
                region,
                id,
                tag_name(addrs, a),
                ip,
                "attached" if attached else "idle",
                PUBLIC_IPV4_HOURLY,
                True,
                "",
            )
        )

    var inst_params: List[FormParam] = [
        FormParam("Filter.1.Name", "instance-state-name"),
        FormParam("Filter.1.Value.1", "pending"),
        FormParam("Filter.1.Value.2", "running"),
    ]
    for page in _paged(client, region, "DescribeInstances", inst_params):
        for i in page.find_all(
            page.root(), "reservationSet/item/instancesSet/item"
        ):
            var itype = page.child_text(i, "instanceType")
            var price = prices.lookup(
                "ec2/" + region + "/" + itype,
                "AmazonEC2",
                ec2_price_filters(region, itype),
                "Hrs",
            )
            var hourly = price.value() if price else 0.0
            var note = String("")
            if page.child_text(i, "instanceLifecycle") == "spot":
                note = "spot: on-demand price shown"
            if page.child_text(i, "platform") == "windows":
                note = "windows: Linux price shown"
            var pub = page.child_text(i, "ipAddress")
            if pub != "" and pub not in eip_ips and price:
                hourly += PUBLIC_IPV4_HOURLY
                note = (note + "; " if note != "" else "") + "+public IPv4"
            out.append(
                Resource(
                    "ec2",
                    region,
                    page.child_text(i, "instanceId"),
                    tag_name(page, i),
                    itype,
                    page.find_text(i, "instanceState/name"),
                    hourly,
                    Bool(price),
                    note,
                )
            )

    for page in _paged(client, region, "DescribeVolumes", List[FormParam]()):
        for v in page.find_all(page.root(), "volumeSet/item"):
            var vtype = page.child_text(v, "volumeType")
            var size = 0
            try:
                size = atol(page.child_text(v, "size"))
            except:
                pass
            var gb_mo = prices.lookup(
                "ebs/" + region + "/" + vtype,
                "AmazonEC2",
                ebs_price_filters(region, vtype),
                "GB-Mo",
            )
            var note = String("")
            if vtype == "io1" or vtype == "io2" or vtype == "gp3":
                note = "storage only (no IOPS/throughput)"
            out.append(
                Resource(
                    "ebs",
                    region,
                    page.child_text(v, "volumeId"),
                    tag_name(page, v),
                    vtype + " " + String(size) + " GiB",
                    page.child_text(v, "status"),
                    ebs_hourly(gb_mo.value(), size) if gb_mo else 0.0,
                    Bool(gb_mo),
                    note,
                )
            )

    var nat_params: List[FormParam] = [
        FormParam("Filter.1.Name", "state"),
        FormParam("Filter.1.Value.1", "pending"),
        FormParam("Filter.1.Value.2", "available"),
    ]
    for page in _paged(client, region, "DescribeNatGateways", nat_params):
        for n in page.find_all(page.root(), "natGatewaySet/item"):
            var price = prices.lookup(
                "nat/" + region, "AmazonEC2", nat_price_filters(region), "Hrs"
            )
            var conn = page.child_text(n, "connectivityType", "public")
            out.append(
                Resource(
                    "nat",
                    region,
                    page.child_text(n, "natGatewayId"),
                    tag_name(page, n),
                    conn,
                    page.child_text(n, "state"),
                    price.value() if price else 0.0,
                    Bool(price),
                    "hourly only (no data processing)",
                )
            )
    return out^


def _bill_to_json(bill: Bill, at: Int) -> String:
    var out = String('{"at": ') + String(at) + ', "bill": {'
    out += '"month_to_date": ' + fmt_float(bill.month_to_date)
    out += ', "currency": ' + json_str(bill.currency)
    out += ', "start": ' + json_str(bill.start)
    out += ', "end": ' + json_str(bill.end)
    out += ', "by_service": ['
    for k in range(len(bill.by_service)):
        if k > 0:
            out += ", "
        out += '{"service": ' + json_str(bill.by_service[k].service)
        out += ', "amount": ' + fmt_float(bill.by_service[k].amount) + "}"
    out += "]}}\n"
    return out^


def _cached_bill(now: Int) -> Optional[Bill]:
    var text = _read(cache_dir() + "/bill.json")
    if text == "":
        return None
    try:
        var doc = JsonDoc.parse(text)
        if now - Int(doc.num(doc.get(doc.root(), "at"))) >= BILL_TTL:
            return None
        var b = doc.get(doc.root(), "bill")
        if b == NONE:
            return None
        var services = List[ServiceCost]()
        for s in doc.children(doc.get(b, "by_service")):
            services.append(
                ServiceCost(
                    doc.str(s, "service"), doc.num(doc.get(s, "amount"))
                )
            )
        return Bill(
            doc.num(doc.get(b, "month_to_date")),
            doc.str(b, "currency", "USD"),
            services^,
            doc.str(b, "start"),
            doc.str(b, "end"),
        )
    except:
        return None


def month_to_date(client: AwsClient, force: Bool = False) raises -> Bill:
    var now = epoch_now()
    if not force:
        var cached = _cached_bill(now)
        if cached:
            return cached.take()
    var period = billing_period(now)
    var body = (
        '{"TimePeriod":{"Start":"'
        + period[0]
        + '","End":"'
        + period[1]
        + '"},"Granularity":"MONTHLY","Metrics":["UnblendedCost"],'
        + '"GroupBy":[{"Type":"DIMENSION","Key":"SERVICE"}]}'
    )
    var bill: Bill
    try:
        var resp = client.json_call(
            "ce.us-east-1.amazonaws.com",
            "us-east-1",
            "ce",
            "AWSInsightsIndexService.GetCostAndUsage",
            body,
        )
        bill = parse_cost_and_usage(resp)
    except e:
        # Early on the 1st the month has no ingested data yet: that is a
        # $0.00 month so far, not a failure.
        if String(e).find("DataUnavailableException") < 0:
            raise e^
        bill = Bill(0.0, "USD", List[ServiceCost](), period[0], period[1])
    _write(cache_dir() + "/bill.json", _bill_to_json(bill, now))
    return bill^
