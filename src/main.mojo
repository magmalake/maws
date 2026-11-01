"""`maws` — AWS resources, estimated cost per hour and the month-to-date bill.

    maws [--profile P] [--region R ...] [--interval SECONDS] [--once]

`--once` prints the tables and exits; otherwise a full-screen view refreshes
every `--interval` seconds (default 60). Resource listing and pricing are
free API calls; the bill is one Cost Explorer call ($0.01), cached for an
hour and re-read on demand with `b`.
"""

from std.sys import argv

from sigv4.signer import epoch_now

from maws.aws import PriceCache, list_resources, month_to_date
from maws.client import AwsClient
from maws.credentials import load_credentials, load_region
from maws.http import curl_version
from maws.model import Bill, Resource, sort_by_hourly
from maws.tui import Screen, print_once, read_key

comptime VERSION = "0.1.1"


@fieldwise_init
struct Args(Copyable, Movable):
    var profile: String
    var regions: List[String]
    var interval: Int
    var once: Bool


def usage():
    print(
        "usage: maws [--profile P] [--region R ...] [--interval SECONDS]"
        " [--once] [--version]"
    )


def parse_args() raises -> Args:
    var a = Args(String(""), List[String](), 60, False)
    var args = argv()
    var k = 1
    while k < len(args):
        var s = String(args[k])
        if s == "--once":
            a.once = True
        elif (
            s == "--profile" or s == "--region" or s == "--interval"
        ) and k + 1 < len(args):
            var v = String(args[k + 1])
            k += 1
            if s == "--profile":
                a.profile = v
            elif s == "--region":
                a.regions.append(v)
            else:
                a.interval = atol(v)
        elif s == "--version":
            print("maws", VERSION, "·", curl_version())
            raise Error("__exit__")
        else:
            usage()
            raise Error("__exit__")
        k += 1
    if len(a.regions) == 0:
        a.regions.append(load_region(a.profile))
    return a^


@fieldwise_init
struct Snapshot(Movable):
    var resources: List[Resource]
    var bill: Optional[Bill]
    var bill_error: String
    var error: String


def gather(
    client: AwsClient, regions: List[String], force_bill: Bool
) -> Snapshot:
    var resources = List[Resource]()
    var error = String("")
    # One region failing (an SCP that denies it, a disabled opt-in region)
    # must not hide the others.
    var prices = PriceCache(client)
    for k in range(len(regions)):
        try:
            resources.extend(list_resources(client, regions[k], prices))
        except e:
            error += ("; " if error != "" else "") + String(e)
    sort_by_hourly(resources)
    var bill: Optional[Bill] = None
    var bill_error = String("")
    try:
        bill = month_to_date(client, force_bill)
    except e:
        bill_error = String(e)
    return Snapshot(resources^, bill^, bill_error^, error^)


def _clock() -> String:
    var t = epoch_now() % 86400
    var h = t // 3600
    var m = (t // 60) % 60
    var s = t % 60
    return (
        ("0" if h < 10 else "")
        + String(h)
        + ":"
        + ("0" if m < 10 else "")
        + String(m)
        + ":"
        + ("0" if s < 10 else "")
        + String(s)
        + "Z"
    )


def main() raises:
    var a: Args
    try:
        a = parse_args()
    except e:
        if String(e) == "__exit__":
            return
        raise e^
    var creds = load_credentials(a.profile)
    var client = AwsClient(creds)
    # Which account the numbers belong to: a member account of an
    # Organization only sees its own bill, so a $0 here next to a non-zero
    # bill in the console usually means "different account".
    var account: String
    try:
        account = "account " + client.account_id(a.regions[0])
    except:
        account = String("account ?")
    try:
        var name = client.account_name()
        if name != "":
            account = name + " (" + account + ")"
    except:
        pass  # no account:GetAccountInformation — the ID alone will do
    var title = account + " · " + creds.source + " · "
    for k in range(len(a.regions)):
        title += ("" if k == 0 else ", ") + a.regions[k]

    if a.once:
        var snap = gather(client, a.regions, False)
        print_once(title, snap.resources, snap.bill, snap.bill_error)
        if snap.error != "":
            print()
            print("warning: " + snap.error)
        return

    var screen = Screen()
    try:
        var force_bill = False
        while True:
            screen.draw(title, List[Resource](), None, "loading…")
            var snap = gather(client, a.regions, force_bill)
            force_bill = False
            var status = "updated " + _clock()
            if snap.error != "":
                status = "error: " + snap.error
            elif snap.bill_error != "":
                status += " · bill: " + snap.bill_error
            screen.draw(title, snap.resources, snap.bill, status)
            var deadline = epoch_now() + a.interval
            var quit = False
            while epoch_now() < deadline:
                var key = read_key(500)
                if key == 113 or key == 81 or key == 3:  # q, Q, Ctrl-C
                    quit = True
                    break
                if key == 114:  # r
                    break
                if key == 98:  # b
                    force_bill = True
                    break
                if key == -1:
                    continue
            if quit:
                break
    finally:
        screen.restore()
