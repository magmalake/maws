"""`maws.client` — signed calls to the two AWS protocol families maws needs.

* **JSON 1.1** (Cost Explorer, Pricing): `POST /` with a JSON body and an
  `X-Amz-Target: <Service>.<Operation>` header; errors come back as
  `{"__type": "...", "message": "..."}`.
* **Query** (EC2): `POST /` with a form-encoded `Action=…&Version=…` body;
  responses and errors are XML.

Both are a POST to `/`, so signing never involves a query string or a path
beyond the root — the narrowest use of sigv4.mojo there is. Throttling and
5xx answers are retried with exponential backoff; anything else is raised as
`AwsError`-style text carrying the service's own code and message.
"""

from std.time import sleep

from sigv4.crypto import sha256_hex
from sigv4.signer import AmzTime, Header, QueryParam, sign_request, url_encode
from xml import Document, NO_NODE

from .credentials import Credentials
from .http import HttpResponse, request
from .jsonlite import JsonDoc, NONE

comptime EC2_API_VERSION = "2016-11-15"
comptime STS_API_VERSION = "2011-06-15"
comptime USER_AGENT = "maws/0.1.1"
comptime MAX_ATTEMPTS = 4


@fieldwise_init
struct FormParam(Copyable, Movable):
    var name: String
    var value: String


def form_encode(params: List[FormParam]) -> String:
    var out = String("")
    for k in range(len(params)):
        if k > 0:
            out += "&"
        out += url_encode(params[k].name, encode_slash=True)
        out += "="
        out += url_encode(params[k].value, encode_slash=True)
    return out^


def _retryable(status: Int, code: String) -> Bool:
    if status >= 500 or status == 429:
        return True
    return (
        code.find("Throttl") >= 0
        or code == "RequestLimitExceeded"
        or code == "RequestThrottled"
        or code == "LimitExceededException"
    )


def json_error_code(body: String) -> String:
    """`__type` of a JSON-1.1 error, namespace stripped (`a.b#Code` → `Code`).
    """
    try:
        var doc = JsonDoc.parse(body)
        var t = doc.str(doc.root(), "__type")
        var hash = t.find("#")
        if hash >= 0:
            return String(t[byte = hash + 1 :])
        return t
    except:
        return String("")


def json_error_message(body: String) -> String:
    try:
        var doc = JsonDoc.parse(body)
        var m = doc.str(doc.root(), "message")
        if m == "":
            m = doc.str(doc.root(), "Message")
        return m
    except:
        return body


def xml_error(body: String) -> Tuple[String, String]:
    """`(Code, Message)` of an EC2 `<Response><Errors><Error>` body."""
    try:
        var doc = Document.parse(body)
        var e = doc.find(doc.root(), "Errors/Error")
        if e == NO_NODE:
            e = doc.find(doc.root(), "Error")
        if e != NO_NODE:
            return Tuple(
                doc.child_text(e, "Code"), doc.child_text(e, "Message")
            )
    except:
        pass
    return Tuple(String(""), body)


struct AwsClient(Copyable, Movable):
    var creds: Credentials

    def __init__(out self, creds: Credentials):
        self.creds = creds.copy()

    def _send(
        self,
        host: String,
        region: String,
        service: String,
        content_type: String,
        target: String,
        body: String,
        path: String = "/",
    ) raises -> HttpResponse:
        if not self.creds.is_set():
            raise Error(
                "no AWS credentials (set"
                " AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or add the profile to"
                " ~/.aws/credentials)"
            )
        var when = AmzTime.now()
        var headers: List[Header] = [
            Header("host", host),
            Header("x-amz-date", when.amz_date),
            Header("content-type", content_type),
        ]
        if target != "":
            headers.append(Header("x-amz-target", target))
        # Unsigned. libcurl sends no User-Agent by default, and the Account
        # Management endpoint answers a UA-less request with a bare 403.
        var unsigned: List[Header] = [Header("user-agent", USER_AGENT)]
        if self.creds.session_token != "":
            headers.append(
                Header("x-amz-security-token", self.creds.session_token)
            )
        var signed = sign_request(
            "POST",
            path,
            List[QueryParam](),
            headers,
            sha256_hex(body),
            self.creds.access_key_id,
            self.creds.secret_access_key,
            region,
            service,
            when,
            True,
        )
        headers.append(Header("authorization", signed.authorization))
        headers.extend(unsigned^)
        return request("POST", "https://" + host + path, headers, body)

    def json_call(
        self,
        host: String,
        region: String,
        service: String,
        target: String,
        body: String,
    ) raises -> String:
        """A JSON-1.1 operation; returns the response body on 2xx."""
        var attempt = 0
        while True:
            var resp = self._send(
                host,
                region,
                service,
                "application/x-amz-json-1.1",
                target,
                body,
            )
            if resp.ok():
                return resp.body
            var code = json_error_code(resp.body)
            attempt += 1
            if attempt < MAX_ATTEMPTS and _retryable(resp.status, code):
                sleep(0.25 * Float64(1 << attempt))
                continue
            raise Error(
                service
                + " "
                + target
                + ": HTTP "
                + String(resp.status)
                + " "
                + code
                + ": "
                + json_error_message(resp.body)
            )

    def query_call(
        self,
        host: String,
        region: String,
        service: String,
        version: String,
        action: String,
        params: List[FormParam],
    ) raises -> Document:
        """A Query-protocol operation (EC2, STS); returns the parsed XML."""
        var all: List[FormParam] = [
            FormParam("Action", action),
            FormParam("Version", version),
        ]
        for k in range(len(params)):
            all.append(params[k].copy())
        var body = form_encode(all)
        var attempt = 0
        while True:
            var resp = self._send(
                host,
                region,
                service,
                "application/x-www-form-urlencoded; charset=utf-8",
                "",
                body,
            )
            if resp.ok():
                return Document.parse(resp.body)
            var err = xml_error(resp.body)
            attempt += 1
            if attempt < MAX_ATTEMPTS and _retryable(resp.status, err[0]):
                sleep(0.25 * Float64(1 << attempt))
                continue
            raise Error(
                service
                + " "
                + action
                + " ("
                + region
                + "): HTTP "
                + String(resp.status)
                + " "
                + err[0]
                + ": "
                + err[1]
            )

    def ec2_call(
        self, region: String, action: String, params: List[FormParam]
    ) raises -> Document:
        """An EC2 Query operation; returns the parsed XML response."""
        return self.query_call(
            "ec2." + region + ".amazonaws.com",
            region,
            "ec2",
            EC2_API_VERSION,
            action,
            params,
        )

    def account_id(self, region: String) raises -> String:
        """The 12-digit account the credentials belong to, from STS
        `GetCallerIdentity` — free, and needs no IAM permission at all."""
        var doc = self.query_call(
            "sts." + region + ".amazonaws.com",
            region,
            "sts",
            STS_API_VERSION,
            "GetCallerIdentity",
            List[FormParam](),
        )
        return doc.find_text(doc.root(), "GetCallerIdentityResult/Account")

    def account_name(self) raises -> String:
        """The account's display name (what the console's account menu shows),
        from the Account Management API — a REST-JSON `POST
        /getAccountInformation`. Needs `account:GetAccountInformation`, which
        many roles lack, so callers treat failure as "unknown"."""
        var resp = self._send(
            "account.us-east-1.amazonaws.com",
            "us-east-1",
            "account",
            "application/json",
            "",
            "{}",
            "/getAccountInformation",
        )
        if not resp.ok():
            raise Error(
                "account GetAccountInformation: HTTP "
                + String(resp.status)
                + " "
                + json_error_message(resp.body)
            )
        var doc = JsonDoc.parse(resp.body)
        return doc.str(doc.root(), "AccountName")
