"""``maws-py`` — the Textual front end.

    maws-py [--profile P] [--region R ...] [--once]

``--once`` prints the same tables to stdout and exits, which is what the
Mojo build is checked against.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone

import boto3
from textual import work
from textual.app import App, ComposeResult
from textual.containers import Horizontal
from textual.widgets import DataTable, Footer, Header, Static

from .aws import PriceCache, list_resources, month_to_date
from .model import Bill, Resource, projected_month, total_hourly


def _usd(v: float | None, places: int = 2) -> str:
    return "?" if v is None else f"${v:,.{places}f}"


def summary_line(resources: list[Resource], bill: Bill | None, now: datetime) -> str:
    hourly = total_hourly(resources)
    unknown = sum(1 for r in resources if r.hourly is None)
    proj = projected_month(bill, hourly, now)
    parts = [
        f"burn {_usd(hourly, 4)}/hr ({_usd(hourly * 24)}/day)",
        f"month-to-date {_usd(bill.month_to_date if bill else None)}",
        f"projected {_usd(proj)}",
    ]
    if unknown:
        parts.append(f"{unknown} unpriced")
    return "   ".join(parts)


def gather(session: boto3.Session, regions: list[str], force_bill: bool = False):
    prices = PriceCache(session)
    resources: list[Resource] = []
    errors: list[str] = []
    # One region failing (an SCP that denies it, a disabled opt-in region)
    # must not hide the others.
    for region in regions:
        try:
            resources.extend(list_resources(session, region, prices))
        except Exception as e:
            errors.append(f"{region}: {e}")
    resources.sort(key=lambda r: -(r.hourly if r.hourly is not None else -1.0))
    bill: Bill | None
    try:
        bill = month_to_date(session, force=force_bill)
    except Exception as e:  # Cost Explorer not enabled, or no ce:* permission
        errors.append(f"bill: {e}")
        bill = None
    return resources, bill, "; ".join(errors)


class MawsApp(App):
    TITLE = "maws"
    CSS = """
    #summary { height: auto; min-height: 3; padding: 1 2; background: $boost; text-style: bold; }
    #resources { width: 2fr; }
    #services { width: 1fr; }
    """
    BINDINGS = [("r", "refresh", "Refresh"), ("b", "refresh_bill", "Refresh bill ($0.01)"), ("q", "quit", "Quit")]

    def __init__(self, session: boto3.Session, regions: list[str], interval: float):
        super().__init__()
        self.session = session
        self.regions = regions
        self.interval = interval

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("loading…", id="summary")
        with Horizontal():
            yield DataTable(id="resources", zebra_stripes=True)
            yield DataTable(id="services", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = f"{self.session.profile_name or 'default'} · {', '.join(self.regions)}"
        res = self.query_one("#resources", DataTable)
        res.add_columns("kind", "region", "id", "name", "detail", "state", "$/hr", "note")
        svc = self.query_one("#services", DataTable)
        svc.add_columns("service (MTD)", "amount")
        self.load()
        self.set_interval(self.interval, self.load)

    def action_refresh(self) -> None:
        self.load()

    def action_refresh_bill(self) -> None:
        self.load(force_bill=True)

    @work(thread=True, exclusive=True)
    def load(self, force_bill: bool = False) -> None:
        try:
            resources, bill, error = gather(self.session, self.regions, force_bill)
        except Exception as e:
            self.call_from_thread(self.query_one("#summary", Static).update, f"error: {e}")
            return
        self.call_from_thread(self._show, resources, bill, error)

    def _show(self, resources: list[Resource], bill: Bill | None, error: str) -> None:
        now = datetime.now(timezone.utc)
        self.query_one("#summary", Static).update(
            summary_line(resources, bill, now)
            + f"   · {now.astimezone():%H:%M:%S}"
            + (f"\n[red]{error}[/]" if error else "")
        )
        res = self.query_one("#resources", DataTable)
        res.clear()
        for r in resources:
            res.add_row(r.kind, r.region, r.id, r.name, r.detail, r.state, _usd(r.hourly, 4), r.note)
        svc = self.query_one("#services", DataTable)
        svc.clear()
        if bill is None:
            svc.add_row("Cost Explorer unavailable", "")
        else:
            for s in bill.by_service:
                svc.add_row(s.service, _usd(s.amount))


def print_once(resources: list[Resource], bill: Bill | None, error: str = "") -> None:
    now = datetime.now(timezone.utc)
    print(summary_line(resources, bill, now))
    print()
    print(f"{'kind':5} {'region':14} {'id':24} {'name':20} {'detail':18} {'state':10} {'$/hr':>9}  note")
    for r in resources:
        print(
            f"{r.kind:5} {r.region:14} {r.id:24} {r.name[:20]:20} {r.detail[:18]:18} "
            f"{r.state:10} {_usd(r.hourly, 4):>9}  {r.note}"
        )
    if bill is not None:
        print()
        print(f"month to date ({bill.start} → {bill.end})")
        for s in bill.by_service:
            print(f"  {s.service[:44]:44} {_usd(s.amount):>12}")
    if error:
        print()
        print(f"warning: {error}")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="maws-py", description=__doc__.splitlines()[0])
    p.add_argument("--profile")
    p.add_argument("--region", action="append", dest="regions", help="repeatable; default: the profile's region")
    p.add_argument("--interval", type=float, default=60.0, help="seconds between resource refreshes")
    p.add_argument("--once", action="store_true", help="print once and exit (no TUI)")
    args = p.parse_args(argv)

    session = boto3.Session(profile_name=args.profile)
    regions = args.regions or [session.region_name or "us-east-1"]
    if args.once:
        print_once(*gather(session, regions))
        return
    MawsApp(session, regions, args.interval).run()


if __name__ == "__main__":
    main()
