# maws — Python reference

The behavioural reference for the Mojo `maws`: same resources, same
price-list parsing, same caches (`~/.cache/maws`), same numbers. Built on
boto3 + Textual.

```bash
uv run --project py_reference maws-py            # TUI: r refresh, b re-read bill, q quit
uv run --project py_reference maws-py --once     # print and exit
uv run --project py_reference maws-py --profile prod --region us-east-1 --region eu-west-1
uv run --project py_reference pytest
```

See the top-level README for what is priced and what is not.
