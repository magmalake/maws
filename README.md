# maws

[![CI](https://github.com/magmalake/maws/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/maws/actions/workflows/ci.yml)

Part of [**magmalake**](https://magmalake.org).

**What is running in my AWS account, what is it costing me per hour, and what
have I been billed so far this month?** — in one terminal screen, written in
[Mojo](https://www.modular.com/mojo).

```
 maws · Hold My Coffee (account 123456789012) · aws cli dista-bench · us-east-2
burn $0.1342/hr ($3.22/day)   month-to-date $41.87   projected $132.50

kind  region         id                       name                 detail             state           $/hr  note
ec2   us-east-2      i-0abc…                  bench-runner         c7i.xlarge         running      $0.1785  +public IPv4
nat   us-east-2      nat-0def…                                     public             available    $0.0450  hourly only (no data processing)
ebs   us-east-2      vol-0123…                                     gp3 100 GiB        in-use       $0.0110  storage only (no IOPS/throughput)
eip   us-east-2      eipalloc-0456…                                3.14.15.92         idle         $0.0050

month to date by service (2026-11-01 → 2026-11-18)
  Amazon Elastic Compute Cloud - Compute            $31.02
  EC2 - Other                                         $8.40
 r refresh   b re-read bill ($0.01)   q quit   updated 13:11:54Z
```

*(illustrative numbers)*

```bash
maws                                   # the profile's region, refresh every 60 s
maws --profile prod --region us-east-1 --region eu-west-1
maws --once                            # print and exit
```

## What the numbers mean

- **$/hr** is the **on-demand list price** from the AWS Pricing API for each
  running resource: EC2 instances (Linux, shared tenancy), EBS volumes
  (storage GB-month ÷ 730), NAT gateways (hourly charge), and public IPv4
  addresses ($0.005/hr each — Elastic IPs, attached or idle, and auto-assigned
  instance IPs). Spot, Reserved Instances, Savings Plans, IOPS/throughput and
  data processing are **not** reflected; the note column says so per row.
- **month-to-date** is Cost Explorer's unblended cost, grouped by service. It
  lags real usage by roughly 8–24 hours, and it covers **only the account in
  the header** — a member account of an AWS Organization does not see the rest
  of the organization's bill; the management account does.
- **projected** = month-to-date + current burn × hours left in the month: "if
  nothing changes". Usage-priced services (S3, data transfer) only show up via
  the bill.

**Cost:** listing and pricing are free API calls. Each Cost Explorer call is
billed at **$0.01**, so the bill is cached for an hour (`~/.cache/maws/bill.json`)
and only re-read on demand with `b`. Prices are cached for 7 days
(`~/.cache/maws/prices.json`). `MAWS_CACHE_DIR` moves both.

**Permissions:** `ec2:DescribeInstances`, `ec2:DescribeVolumes`,
`ec2:DescribeNatGateways`, `ec2:DescribeAddresses`, `pricing:GetProducts`,
`ce:GetCostAndUsage`; optionally `account:GetAccountInformation`, which puts
the account's name next to its ID in the header (the ID itself comes from STS
`GetCallerIdentity`, which needs no permission). A region your account cannot read (an SCP, a disabled
opt-in region) is reported as a warning and the others still show.

## Credentials

1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`;
2. static keys in `~/.aws/credentials` for the profile (`--profile`, else
   `AWS_PROFILE`, else `default`);
3. anything else — `aws login`, SSO, `credential_process`, assume-role — is
   resolved by the AWS CLI via `aws configure export-credentials`.

Region: `--region` (repeatable), else `AWS_REGION`, `AWS_DEFAULT_REGION`, then
the profile's `region` in `~/.aws/config`.

## How it is built

No AWS SDK, no Python at runtime, and no C shim:

| piece | where |
|---|---|
| SigV4 signing, SHA-256, HMAC | [sigv4.mojo](https://github.com/magmalake/sigv4.mojo) |
| EC2 Query-API (XML) responses | [xml.mojo](https://github.com/magmalake/xml.mojo) |
| HTTPS | libcurl, called directly with `external_call` (variadic `curl_easy_setopt` via `num_fixed_args`); bodies land in an `open_memstream` buffer, so no C callback is needed — `src/maws/http.mojo` |
| JSON-1.1 responses (Cost Explorer, Pricing) | a flat read-only JSON tree, `src/maws/jsonlite.mojo` |
| TUI | ANSI escapes, `stty`, `poll` — `src/maws/tui.mojo` |

`py_reference/` is the same tool in Python (boto3 + Textual). It is the
behavioural reference: same resources, same price-list parsing, same caches,
same `--once` layout. `tests/maws_test.mojo` asserts the same cases as
`py_reference/tests/test_model.py`.

## Build

sigv4.mojo and xml.mojo are consumed by source path, so check them out next
to this repository:

```bash
git clone git@github.com:magmalake/maws.git
git clone git@github.com:magmalake/sigv4.mojo.git
git clone git@github.com:magmalake/xml.mojo.git
cd maws
pixi run -e stable build        # → build/maws (Mojo 1.2.0; `pixi run build` for nightly)
pixi run -e stable test         # MAWS_LIVE_PROFILE=<profile> adds a live Pricing lookup
uv run --project py_reference maws-py --once
```

## License

Apache-2.0.
