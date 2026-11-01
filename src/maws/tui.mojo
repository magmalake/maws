"""`maws.tui` — a full-screen view with nothing but ANSI escapes and libc.

The terminal goes into non-canonical, no-echo, no-signal mode (`stty`), so
single keys arrive immediately and Ctrl-C is a key rather than a signal that
would leave the terminal raw. `poll` on stdin doubles as the refresh timer.
Everything is redrawn on each frame; at a few dozen rows that is cheaper
than tracking what changed.
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.sys.info import CompilationTarget

from sigv4.signer import epoch_now

from .model import Bill, Resource, projected_month, total_hourly, unpriced_count

comptime ESC = "\x1b["


def fmt_fixed(v: Float64, places: Int) -> String:
    """`v` rounded to `places` decimals, with thousands separators."""
    var neg = v < 0.0
    var x = -v if neg else v
    var scale = 1
    for _ in range(places):
        scale *= 10
    var scaled = Int(x * Float64(scale) + 0.5)
    var whole = scaled // scale
    var frac = scaled % scale
    var digits = String(whole)
    var grouped = String("")
    var n = digits.byte_length()
    for k in range(n):
        if k > 0 and (n - k) % 3 == 0:
            grouped += ","
        grouped += String(digits[byte = k : k + 1])
    var out = ("-" if neg else "") + grouped
    if places > 0:
        var f = String(frac)
        while f.byte_length() < places:
            f = "0" + f
        out += "." + f
    return out^


def usd(v: Float64, places: Int = 2) -> String:
    return "$" + fmt_fixed(v, places)


def usd_opt(v: Optional[Float64], places: Int = 2) -> String:
    return usd(v.value(), places) if v else String("?")


def cell(s: String, width: Int, right: Bool = False) -> String:
    """`s` padded or cut to exactly `width` columns (ASCII-width approximation:
    a multi-byte character counts once)."""
    var cps = List[String]()
    for cp in s.codepoint_slices():
        cps.append(String(cp))
    var out = String("")
    if len(cps) > width:
        for k in range(width - 1 if width > 0 else 0):
            out += cps[k]
        if width > 0:
            out += "…"
        return out^
    var pad = String("")
    for _ in range(width - len(cps)):
        pad += " "
    return pad + s if right else s + pad


def summary_line(
    resources: List[Resource], bill: Optional[Bill], epoch: Int
) -> String:
    var hourly = total_hourly(resources)
    var mtd: Optional[Float64] = None
    if bill:
        mtd = bill.value().month_to_date
    var out = "burn " + usd(hourly, 4) + "/hr (" + usd(hourly * 24.0) + "/day)"
    out += "   month-to-date " + usd_opt(mtd)
    out += "   projected " + usd_opt(projected_month(bill, hourly, epoch))
    var unknown = unpriced_count(resources)
    if unknown > 0:
        out += "   " + String(unknown) + " unpriced"
    return out^


def resource_header() -> String:
    return (
        cell("kind", 5)
        + " "
        + cell("region", 14)
        + " "
        + cell("id", 24)
        + " "
        + cell("name", 20)
        + " "
        + cell("detail", 18)
        + " "
        + cell("state", 10)
        + " "
        + cell("$/hr", 9, True)
        + "  note"
    )


def resource_row(r: Resource) -> String:
    var price = usd(r.hourly, 4) if r.priced else String("?")
    return (
        cell(r.kind, 5)
        + " "
        + cell(r.region, 14)
        + " "
        + cell(r.id, 24)
        + " "
        + cell(r.name, 20)
        + " "
        + cell(r.detail, 18)
        + " "
        + cell(r.state, 10)
        + " "
        + cell(price, 9, True)
        + "  "
        + r.note
    )


def print_once(
    title: String,
    resources: List[Resource],
    bill: Optional[Bill],
    bill_error: String,
):
    """The non-interactive `--once` output; same layout as `maws-py --once`."""
    print(title)
    print(summary_line(resources, bill, epoch_now()))
    print()
    print(resource_header())
    for k in range(len(resources)):
        print(resource_row(resources[k]))
    if bill:
        ref b = bill.value()
        print()
        print("month to date (" + b.start + " → " + b.end + ")")
        for k in range(len(b.by_service)):
            print(
                "  "
                + cell(b.by_service[k].service, 44)
                + " "
                + cell(usd(b.by_service[k].amount), 12, True)
            )
    elif bill_error != "":
        print()
        print("bill unavailable: " + bill_error)


# ---------------------------------------------------------------------------
# Terminal
# ---------------------------------------------------------------------------


def _system(cmd: String) -> Int:
    var c = List[UInt8](cmd.as_bytes())
    c.append(0)
    var rc = Int(external_call["system", c_int](Int(c.unsafe_ptr())))
    _ = c^
    return rc


def _out(s: String):
    print(s, end="", flush=True)


def terminal_size() -> Tuple[Int, Int]:
    """`(rows, cols)` from `TIOCGWINSZ`, or 24×80 when stdout is no tty."""
    comptime TIOCGWINSZ = 0x40087468 if CompilationTarget.is_macos() else 0x5413
    var ws = external_call["calloc", Int](Int(1), Int(8))
    var rc = Int(
        external_call["ioctl", c_int, num_fixed_args=2](
            c_int(1), Int(TIOCGWINSZ), ws
        )
    )
    var p = Pointer[UInt16, ImmUntrackedOrigin](unsafe_from_address=ws)
    var rows = Int(p[])
    var cols = Int(
        Pointer[UInt16, ImmUntrackedOrigin](unsafe_from_address=ws + 2)[]
    )
    external_call["free", NoneType](ws)
    if rc != 0 or rows == 0 or cols == 0:
        return Tuple(24, 80)
    return Tuple(rows, cols)


def read_key(timeout_ms: Int) -> Int:
    """The next byte on stdin, or -1 after `timeout_ms` with no input."""
    # struct pollfd { int fd; short events; short revents; }, POLLIN = 1
    var pfd = external_call["calloc", Int](Int(1), Int(8))
    var cell_fd = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=pfd)
    cell_fd[] = 0
    var cell_ev = Pointer[Int16, MutUntrackedOrigin](
        unsafe_from_address=pfd + 4
    )
    cell_ev[] = 1
    var n = Int(external_call["poll", c_int](pfd, Int(1), c_int(timeout_ms)))
    external_call["free", NoneType](pfd)
    if n <= 0:
        return -1
    # `read`, not stdio: a buffered getchar could swallow bytes that poll
    # would then never report. Declared with the stdlib's own signature for
    # the symbol (std.io binds `read` too, and one module may hold only one).
    var byte: List[UInt8] = [0]
    var got = external_call["read", Int](
        c_int(0), byte.unsafe_ptr().unsafe_bitcast[NoneType](), Int(1)
    )
    return Int(byte[0]) if got == 1 else -1


@fieldwise_init
struct Palette(Copyable, Movable):
    """SGR parameter strings for each role, chosen once per run.

    The colours are the magmalake site's: lake teal for the title and key
    bars, ember orange for the money line. 24-bit when the terminal says it
    can (`COLORTERM=truecolor`/`24bit`), the nearest xterm-256 entries
    otherwise, and plain bold/reverse under `NO_COLOR` or `TERM=dumb`.
    """

    var bar: String
    var bar_alert: String
    var accent: String
    var head: String
    var dim: String

    @staticmethod
    def detect() -> Palette:
        var term = getenv("TERM", "")
        if getenv("NO_COLOR", "") != "" or term == "dumb":
            return Palette("1;7", "1;7", "1", "4", "2")
        var ct = getenv("COLORTERM", "")
        if ct == "truecolor" or ct == "24bit":
            return Palette(
                "1;38;2;14;13;17;48;2;78;205;196",
                "1;38;2;14;13;17;48;2;255;122;69",
                "1;38;2;255;122;69",
                "4;38;2;232;228;223",
                "38;2;143;138;150",
            )
        return Palette(
            "1;38;5;16;48;5;80",
            "1;38;5;16;48;5;209",
            "1;38;5;209",
            "4",
            "38;5;245",
        )


def _sgr(params: String, text: String) -> String:
    return ESC + params + "m" + text + ESC + "0m"


struct Screen:
    var pal: Palette

    def __init__(out self):
        self.pal = Palette.detect()
        _ = _system("stty -icanon -echo -isig min 1 2>/dev/null")
        _out(ESC + "?1049h" + ESC + "?25l")

    def restore(self):
        _out(ESC + "?25h" + ESC + "?1049l")
        _ = _system("stty icanon echo isig 2>/dev/null")

    def draw(
        self,
        title: String,
        resources: List[Resource],
        bill: Optional[Bill],
        status: String,
    ):
        var size = terminal_size()
        var rows = size[0]
        var cols = size[1]
        var f = ESC + "H" + ESC + "2J"
        f += _sgr(self.pal.bar, cell(" maws · " + title, cols)) + "\r\n"
        f += _sgr(
            self.pal.accent,
            cell(summary_line(resources, bill, epoch_now()), cols),
        )
        f += "\r\n\r\n"
        var used = 3

        var svc_rows = 0
        if bill:
            svc_rows = len(bill.value().by_service)
        # Resources get what the services table and chrome leave over.
        var budget = rows - used - 3 - (min(svc_rows, 12) + 3)
        if budget < 3:
            budget = 3
        f += _sgr(self.pal.head, cell(resource_header(), cols)) + "\r\n"
        used += 1
        var shown = min(len(resources), budget)
        for k in range(shown):
            f += cell(resource_row(resources[k]), cols) + "\r\n"
        if len(resources) > shown:
            f += (
                _sgr(
                    self.pal.dim,
                    cell("… " + String(len(resources) - shown) + " more", cols),
                )
                + "\r\n"
            )
        if len(resources) == 0:
            f += (
                _sgr(self.pal.dim, "(no billable EC2/EBS/NAT/EIP resources)")
                + "\r\n"
            )

        f += "\r\n"
        if bill:
            ref b = bill.value()
            f += (
                _sgr(
                    self.pal.head,
                    cell(
                        "month to date by service ("
                        + b.start
                        + " → "
                        + b.end
                        + ")",
                        cols,
                    ),
                )
                + "\r\n"
            )
            for k in range(min(len(b.by_service), 12)):
                f += (
                    cell(
                        "  "
                        + cell(b.by_service[k].service, 44)
                        + " "
                        + cell(usd(b.by_service[k].amount), 12, True),
                        cols,
                    )
                    + "\r\n"
                )

        # The key bar turns ember when the status carries an error.
        var bar = self.pal.bar
        if status.startswith("error") or status.find(" · bill:") >= 0:
            bar = self.pal.bar_alert
        f += ESC + String(rows) + ";1H"
        f += _sgr(
            bar,
            cell(
                " r refresh   b re-read bill ($0.01)   q quit   " + status, cols
            ),
        )
        _out(f)
