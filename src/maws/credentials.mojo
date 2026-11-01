"""`maws.credentials` — where the keys and the region come from.

The subset of the AWS SDK resolution chain that covers a workstation:

1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.
2. The `[profile]` section of `~/.aws/credentials`
   (`AWS_SHARED_CREDENTIALS_FILE` overrides the path).

3. For any other kind of profile — `aws login` (`login_session`), SSO,
   `credential_process`, assume-role — the AWS CLI itself, through
   `aws configure export-credentials --format process`. Those flows involve
   token caches and refreshes that are the CLI's business, not ours.

The region is `AWS_REGION`, then `AWS_DEFAULT_REGION`, then `region =` in the
profile's section of `~/.aws/config` (`[default]` or `[profile NAME]`).
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.os.path import exists

from .jsonlite import JsonDoc


@fieldwise_init
struct Credentials(Copyable, Movable):
    var access_key_id: String
    var secret_access_key: String
    var session_token: String
    var source: String
    """Where they were found, for the status line."""

    def is_set(self) -> Bool:
        return self.access_key_id != "" and self.secret_access_key != ""


def _home_file(env: StaticString, rel: StaticString) -> String:
    var p = getenv(env, "")
    if p != "":
        return p
    return getenv("HOME", "") + "/" + rel


def ini_value(text: String, section: String, key: String) -> String:
    """`key = value` from `[section]` of an INI document, or "".

    Section and key match exactly after trimming; `#` and `;` start comment
    lines. This is the dialect the AWS CLI writes.
    """
    var in_section = False
    var lines = text.split("\n")
    for k in range(len(lines)):
        var line = String(String(lines[k]).strip())
        if line == "" or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            var name = String(
                String(line[byte = 1 : line.byte_length() - 1]).strip()
            )
            in_section = name == section
            continue
        if not in_section:
            continue
        var eq = line.find("=")
        if eq < 0:
            continue
        var k_ = String(String(line[byte=0:eq]).strip())
        if k_ == key:
            return String(String(line[byte = eq + 1 :]).strip())
    return String("")


def _read(path: String) -> String:
    if not exists(path):
        return String("")
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return String("")


def resolve_profile(profile: String) -> String:
    if profile != "":
        return profile
    var p = getenv("AWS_PROFILE", "")
    return p if p != "" else String("default")


def run_capture(cmd: String) -> String:
    """stdout of `cmd` run through `/bin/sh`, or "" if it could not start."""
    var c = List[UInt8](cmd.as_bytes())
    c.append(0)
    var mode: List[UInt8] = [114, 0]  # "r"
    var fp = external_call["popen", Int](
        Int(c.unsafe_ptr()), Int(mode.unsafe_ptr())
    )
    if fp == 0:
        return String("")
    var out = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=0)
    while True:
        var n = external_call["fread", Int](
            Int(buf.unsafe_ptr()), Int(1), Int(4096), fp
        )
        if n <= 0:
            break
        for k in range(n):
            out.append(buf[k])
    _ = external_call["pclose", c_int](fp)
    _ = c^
    _ = mode^
    return String(from_utf8_lossy=Span(out))


def _shell_quote(s: String) -> String:
    return "'" + s.replace("'", "'\\''") + "'"


def cli_credentials(profile: String) -> Credentials:
    """Asks the AWS CLI to resolve `profile` (login, SSO, process, role)."""
    var cmd = String("aws configure export-credentials --format process")
    if profile != "":
        cmd += " --profile " + _shell_quote(profile)
    var text = run_capture(cmd + " 2>/dev/null")
    try:
        var doc = JsonDoc.parse(text)
        var r = doc.root()
        return Credentials(
            doc.str(r, "AccessKeyId"),
            doc.str(r, "SecretAccessKey"),
            doc.str(r, "SessionToken"),
            "aws cli " + resolve_profile(profile),
        )
    except:
        return Credentials(String(""), String(""), String(""), String(""))


def load_credentials(profile: String) -> Credentials:
    var env_key = getenv("AWS_ACCESS_KEY_ID", "")
    var env_secret = getenv("AWS_SECRET_ACCESS_KEY", "")
    if env_key != "" and env_secret != "":
        return Credentials(
            env_key, env_secret, getenv("AWS_SESSION_TOKEN", ""), "env"
        )
    var path = _home_file("AWS_SHARED_CREDENTIALS_FILE", ".aws/credentials")
    var text = _read(path)
    var name = resolve_profile(profile)
    var static = Credentials(
        ini_value(text, name, "aws_access_key_id"),
        ini_value(text, name, "aws_secret_access_key"),
        ini_value(text, name, "aws_session_token"),
        "profile " + name,
    )
    if static.is_set():
        return static^
    var cli = cli_credentials(name)
    if cli.is_set():
        return cli^
    return static^


def load_region(profile: String) -> String:
    var r = getenv("AWS_REGION", "")
    if r != "":
        return r
    r = getenv("AWS_DEFAULT_REGION", "")
    if r != "":
        return r
    var text = _read(_home_file("AWS_CONFIG_FILE", ".aws/config"))
    var name = resolve_profile(profile)
    var section = name if name == "default" else "profile " + name
    r = ini_value(text, section, "region")
    return r if r != "" else String("us-east-1")
