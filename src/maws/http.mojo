"""`maws.http` — one HTTPS request at a time, over libcurl, with no shim.

objectstore.mojo wraps libcurl in a small C library because
`curl_easy_setopt` is variadic and a `dlopen`ed symbol cannot be called
variadically. `external_call` *can* (`num_fixed_args`), as long as libcurl is
linked at build time (`-Xlinker -lcurl`, see pixi.toml), so this module
calls it directly and the project needs no C toolchain at all.

The other half of a shim's job is the write callback. That is avoided too:
with no `CURLOPT_WRITEFUNCTION` set, libcurl `fwrite`s the body to the
`FILE *` in `CURLOPT_WRITEDATA`, and `open_memstream` gives a `FILE *` that
grows a heap buffer — so the body lands in memory without Mojo ever having
to hand C a function pointer.
"""

from std.ffi import c_int, c_long, c_long_long, external_call

from sigv4.signer import Header

comptime _CURLOPT_WRITEDATA = 10001
comptime _CURLOPT_URL = 10002
comptime _CURLOPT_ERRORBUFFER = 10010
comptime _CURLOPT_HTTPHEADER = 10023
comptime _CURLOPT_CUSTOMREQUEST = 10036
comptime _CURLOPT_POST = 47
comptime _CURLOPT_NOSIGNAL = 99
comptime _CURLOPT_ACCEPT_ENCODING = 10102
comptime _CURLOPT_TIMEOUT_MS = 155
comptime _CURLOPT_POSTFIELDSIZE_LARGE = 30120
comptime _CURLOPT_COPYPOSTFIELDS = 10165
comptime _CURLINFO_RESPONSE_CODE = 0x200002
comptime _CURL_ERROR_SIZE = 256

comptime DEFAULT_TIMEOUT_MS = 30_000


@fieldwise_init
struct HttpResponse(Copyable, Movable):
    var status: Int
    var body: String

    def ok(self) -> Bool:
        return self.status >= 200 and self.status < 300


def _cstr(s: String) -> List[UInt8]:
    var out = List[UInt8](s.as_bytes())
    out.append(0)
    return out^


def _peek_int(addr: Int) -> Int:
    return Pointer[Int, ImmUntrackedOrigin](unsafe_from_address=addr)[]


def _read_cstring(addr: Int) -> String:
    var n = Int(external_call["strlen", c_long](addr))
    var span = Span[UInt8, ImmUntrackedOrigin](
        unsafe_ptr=Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=addr),
        length=n,
    )
    return String(StringSlice(unsafe_from_utf8=span))


def _setopt(h: Int, opt: Int, value: Int) -> Int:
    """Pointer-valued options (`OBJECTPOINT`): the value is an address."""
    return Int(
        external_call["curl_easy_setopt", c_int, num_fixed_args=2](
            h, c_int(opt), value
        )
    )


def _setopt_long(h: Int, opt: Int, value: Int) -> Int:
    return Int(
        external_call["curl_easy_setopt", c_int, num_fixed_args=2](
            h, c_int(opt), c_long(value)
        )
    )


def _setopt_off(h: Int, opt: Int, value: Int) -> Int:
    return Int(
        external_call["curl_easy_setopt", c_int, num_fixed_args=2](
            h, c_int(opt), c_long_long(value)
        )
    )


def request(
    method: String,
    url: String,
    headers: List[Header],
    body: String,
    timeout_ms: Int = DEFAULT_TIMEOUT_MS,
) raises -> HttpResponse:
    """Performs one request. Raises only on transport failure; any HTTP
    status, 4xx and 5xx included, comes back as a response."""
    var h = external_call["curl_easy_init", Int]()
    if h == 0:
        raise Error("http: curl_easy_init failed")

    var url_c = _cstr(url)
    _ = _setopt(h, _CURLOPT_URL, Int(url_c.unsafe_ptr()))
    _ = _setopt_long(h, _CURLOPT_NOSIGNAL, 1)
    _ = _setopt_long(h, _CURLOPT_TIMEOUT_MS, timeout_ms)
    var enc_c = _cstr("")  # "" = every encoding this libcurl can decode
    _ = _setopt(h, _CURLOPT_ACCEPT_ENCODING, Int(enc_c.unsafe_ptr()))

    # Every C string is held in a variable that is explicitly consumed after
    # the last libcurl call. Mojo destroys a value right after its last
    # *Mojo-visible* use, and `Int(x.unsafe_ptr())` is that use, so a
    # temporary would be freed before the foreign call ever read it.
    var lines = List[List[UInt8]]()
    for k in range(len(headers)):
        lines.append(_cstr(headers[k].name + ": " + headers[k].value))
    var slist = 0
    for k in range(len(lines)):
        slist = external_call["curl_slist_append", Int](
            slist, Int(lines[k].unsafe_ptr())
        )
    if slist != 0:
        _ = _setopt(h, _CURLOPT_HTTPHEADER, slist)

    var body_c = _cstr(body)
    var method_c = _cstr(method)
    if method == "POST":
        _ = _setopt_long(h, _CURLOPT_POST, 1)
        _ = _setopt_off(h, _CURLOPT_POSTFIELDSIZE_LARGE, body.byte_length())
        _ = _setopt(h, _CURLOPT_COPYPOSTFIELDS, Int(body_c.unsafe_ptr()))
    elif method != "GET":
        _ = _setopt(h, _CURLOPT_CUSTOMREQUEST, Int(method_c.unsafe_ptr()))

    # open_memstream(&buf, &size): two words, calloc'd so they start at 0.
    var cells = external_call["calloc", Int](Int(2), Int(8))
    var fp = external_call["open_memstream", Int](cells, cells + 8)
    if fp == 0:
        external_call["free", NoneType](cells)
        raise Error("http: open_memstream failed")
    _ = _setopt(h, _CURLOPT_WRITEDATA, fp)
    var errbuf = external_call["calloc", Int](Int(1), Int(_CURL_ERROR_SIZE))
    _ = _setopt(h, _CURLOPT_ERRORBUFFER, errbuf)

    var rc = Int(external_call["curl_easy_perform", c_int](h))
    _ = external_call["fclose", c_int](fp)  # flushes buf/size

    var status_cell = external_call["calloc", Int](Int(1), Int(8))
    _ = external_call["curl_easy_getinfo", c_int, num_fixed_args=2](
        h, c_int(_CURLINFO_RESPONSE_CODE), status_cell
    )
    var status = _peek_int(status_cell)

    var buf = _peek_int(cells)
    var size = _peek_int(cells + 8)
    var out = String("")
    if buf != 0 and size > 0:
        var span = Span[UInt8, ImmUntrackedOrigin](
            unsafe_ptr=Pointer[UInt8, ImmUntrackedOrigin](
                unsafe_from_address=buf
            ),
            length=size,
        )
        out = String(from_utf8_lossy=span)
    var err = String("")
    if rc != 0:
        err = _read_cstring(errbuf)
        if err == "":
            err = _read_cstring(
                external_call["curl_easy_strerror", Int](c_int(rc))
            )

    if buf != 0:
        external_call["free", NoneType](buf)
    external_call["free", NoneType](cells)
    external_call["free", NoneType](errbuf)
    external_call["free", NoneType](status_cell)
    if slist != 0:
        external_call["curl_slist_free_all", NoneType](slist)
    external_call["curl_easy_cleanup", NoneType](h)
    # Keep the C strings alive until libcurl is done with them.
    _ = url_c^
    _ = enc_c^
    _ = body_c^
    _ = method_c^
    _ = lines^

    if rc != 0:
        raise Error("http: " + method + " " + url + ": " + err)
    return HttpResponse(status, out^)


def curl_version() -> String:
    return _read_cstring(external_call["curl_version", Int]())
