"""The review lanes redact credentials from the model's text before it leaves the job.

A PR that adds or removes a credential carries it in its diff, and a review
that quotes the diff quotes the credential. On 2026-10-22 claude-review.yml
put all four WhoisXML API keys that three scrub PRs removed (three of them
live) verbatim into PR comments, and so into every watcher's notification
email. Editing or deleting a comment
afterwards takes nothing back. So each lane installs one redactor before its
model runs, and runs every piece of model text through it BEFORE posting or
printing it; claude-review's inline comments, which claude-code-action's MCP
tool posts, are rewritten on their way into the tool by a PreToolUse hook.

Every planted value below is built at run time from random characters: no
credential, real or fake, is written in this file.

Pinned here:
1. Discovery: claude-review, the adversarial pass and Codex each install the
   redactor with one identical script, before the model step and under the
   same condition, taking no `${{ }}` expression into it; each prompt asks
   the model not to repeat credentials.
2. The redactor, as the shipped script writes it: every shape (WhoisXML,
   AWS, GitHub, Slack, Anthropic, OpenAI, Google, Stripe, JWT, private-key
   blocks whole, cut short or JSON-escaped, URL passwords, Authorization
   values, apiKey=/password:/token: values quoted and bare) planted in
   prose, code, URLs, JSON and YAML comes out with no run of the value left
   and a marker of its kind; ordinary code, identifiers, the lanes' own
   protocol lines and the three lane workflows pass byte for byte; output is
   idempotent and the filter, in-place and check modes agree; no marker
   matches a finding or clean marker the merge gates read.
3. The hook: the review step passes the settings file the install step
   writes; its matcher is the allowlisted inline-comment tool; run as the
   CLI runs it, it returns the input with the body redacted and every other
   field untouched, and no permission decision (the allowlist decides); a
   clean call prints nothing; bad input, a missing redactor or a missing
   python3 exits 2, which blocks the call.
4. The posting steps, run as shipped against a stub gh: the review summary,
   the lost-findings guard (its fallback comment and its denial log lines),
   the adversarial verdict and the Codex review + comment steps never post,
   log or summarize a planted value, healthy or with the comment API down.
   Without the redactor each posts nothing and fails.
5. "Check what the review posted for credentials": a planted value in a
   comment either bot created since the review started fails the job,
   naming the comment and kind but never the value; older comments, other
   authors and clean comments pass; a failed read warns.
6. Negative controls: a dropped pattern, a dropped redaction call in each
   posting step, the hook's `|| exit 2`, `disableAllHooks: false` and
   `--settings` removed, and the check's time filter removed are each caught.
"""

import importlib.util
import json
import os
import random
import re
import shlex
import shutil
import string
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
SCRIPTS = ROOT / ".github" / "scripts"
INLINE_TOOL = "mcp__github_inline_comment__create_inline_comment"
INSTALL = "Install the secret redactor"
SETTINGS_ARG = '--settings "${{ runner.temp }}/secret-redactor/settings.json"'
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")

REVIEW = ("claude-review.yml", "review")
ADVERSARIAL = ("claude-adversarial-review.yml", "adversarial-review")
CODEX = ("codex-review.yml", "codex-review")
LANES = (REVIEW, ADVERSARIAL, CODEX)


def load(workflow):
    return yaml.safe_load((WORKFLOWS / workflow).read_text())


def steps(lane):
    workflow, job = lane
    return load(workflow)["jobs"][job]["steps"]


def find(lane, *, name=None, step_id=None):
    found = [
        s
        for s in steps(lane)
        if (name is None or s.get("name") == name) and (step_id is None or s.get("id") == step_id)
    ]
    assert len(found) == 1, f"{lane[0]}: expected one step name={name!r} id={step_id!r}, found {len(found)}"
    return found[0]


def model_step(lane):
    """The step whose model reads the diff."""
    if lane == CODEX:
        return find(lane, name="Run Codex adversarial review")
    (step,) = [s for s in steps(lane) if str(s.get("uses", "")).startswith("anthropics/claude-code-action@")]
    return step


def shipped(step):
    run = step["run"]
    assert "${{" not in run, "the runner would substitute into this script"
    return run


def install_script(lane=REVIEW):
    return shipped(find(lane, name=INSTALL))


def redactor_source(script=None):
    script = script if script is not None else install_script()
    match = re.search(r"<<'PY'\n(.*?)\nPY\n", script, re.DOTALL)
    assert match, "the install step no longer writes the redactor from a <<'PY' heredoc"
    return match.group(1) + "\n"


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def install(runner_temp, script=None):
    """Run the shipped install step; return the directory it filled."""
    runner_temp.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script or install_script()],
        env={**os.environ, "RUNNER_TEMP": str(runner_temp)},
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return runner_temp / "secret-redactor"


@pytest.fixture(scope="module")
def redactor(tmp_path_factory):
    path = tmp_path_factory.mktemp("redactor") / "redact_secrets.py"
    path.write_text(redactor_source())
    spec = importlib.util.spec_from_file_location("redact_secrets_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# Planted values: built from random characters at run time.

ALNUM = string.ascii_letters + string.digits
UPPER = string.ascii_uppercase + string.digits
B64 = ALNUM + "+/"
B64URL = ALNUM + "_-"
RNG = random.Random(20261022)


def rand(n, alphabet=ALNUM):
    value = "".join(RNG.choice(alphabet) for _ in range(n))
    # A digit and a letter in every value, so no value reads as plain words.
    return value[:-2] + RNG.choice(string.digits) + RNG.choice(string.ascii_letters)


def vendor_values():
    """(kind, value) for every vendor-prefixed shape."""
    return [
        ("whoisxml-api-key", "at_" + rand(29)),
        ("aws-access-key-id", "AKIA" + rand(16, UPPER).upper()),
        ("aws-access-key-id", "ASIA" + rand(16, UPPER).upper()),
        ("github-token", "ghp_" + rand(36)),
        ("github-token", "gho_" + rand(36)),
        ("github-token", "ghu_" + rand(36)),
        ("github-token", "ghs_" + rand(36)),
        ("github-token", "ghr_" + rand(36)),
        ("github-token", "github_pat_" + rand(22) + "_" + rand(59)),
        ("slack-token", "xoxb-" + rand(12, string.digits + "x") + "-" + rand(13, string.digits + "x") + "-" + rand(24)),
        ("slack-token", "xoxp-" + rand(12, string.digits + "x") + "-" + rand(32)),
        ("slack-token", "xoxe.xoxp-1-" + rand(40)),
        ("slack-token", "xapp-1-" + rand(11) + "-" + rand(13, string.digits + "x") + "-" + rand(40)),
        ("slack-webhook", "https://hooks.slack.com/services/T" + rand(10, UPPER) + "/B" + rand(10, UPPER) + "/" + rand(24)),
        ("anthropic-api-key", "sk-ant-api03-" + rand(80, B64URL)),
        ("openai-api-key", "sk-proj-" + rand(60, B64URL) + "T3BlbkFJ" + rand(60, B64URL)),
        ("openai-api-key", "sk-svcacct-" + rand(60, B64URL)),
        ("openai-api-key", "sk-" + rand(20) + "T3BlbkFJ" + rand(20)),
        ("openai-api-key", "sk-" + rand(48)),
        ("google-api-key", "AIza" + rand(35, B64URL)),
        ("npm-token", "npm_" + rand(36)),
        ("gitlab-token", "glpat-" + rand(20, B64URL)),
        ("stripe-key", "sk_live_" + rand(24)),
        ("stripe-key", "rk_test_" + rand(24)),
        ("jwt", "eyJ" + rand(30, B64URL) + ".eyJ" + rand(50, B64URL) + "." + rand(43, B64URL)),
    ]


VENDOR = vendor_values()

# Where a model puts what it quotes. Each takes the value and returns text.
CONTEXTS = {
    "prose": lambda v: f"Line 12 commits {v} in plain text; rotate it.",
    "code span": lambda v: f"Line 12 commits `{v}`.",
    "code block": lambda v: f"```python\nKEY = '{v}'\nprint(KEY)\n```",
    "json escaped newline": lambda v: '{"body": "line one\\n' + v + '\\nline three"}',
    "url query": lambda v: f"curl 'https://api.example.com/v1?domainName=example.com&apiKey={v}&outputFormat=JSON'",
    "yaml": lambda v: f"credentials:\n  value: {v}\n",
    "markdown table": lambda v: f"| file | value |\n| - | - |\n| config.py | {v} |",
    "parenthesised": lambda v: f"(the old value, {v}, is still live)",
}


def tail(value):
    """The value's last 12 characters: a run no surviving fragment may hold."""
    return value[-12:]


def assert_gone(text, values):
    for value in values:
        assert value not in text, "a planted value survived redaction"
        assert tail(value) not in text, "part of a planted value survived redaction"


# ---------------------------------------------------------------------------
# 1. Discovery


@pytest.mark.parametrize("lane", LANES, ids=lambda lane: lane[0])
def test_each_lane_installs_the_redactor_before_its_model_step(lane):
    names = [s.get("name") for s in steps(lane)]
    install_step = find(lane, name=INSTALL)
    model = model_step(lane)
    assert install_step.get("id") == "redactor"
    assert names.index(INSTALL) < names.index(model.get("name")), (
        f"{lane[0]}: the redactor must be installed before the model runs"
    )
    # Installed whenever the model runs: the same condition, or none on both.
    assert install_step.get("if") == model.get("if"), (
        f"{lane[0]}: the install step's if: {install_step.get('if')!r} differs from the model step's {model.get('if')!r}"
    )


def test_every_lane_runs_one_install_script():
    scripts = {lane[0]: install_script(lane) for lane in LANES}
    assert len(set(scripts.values())) == 1, (
        "the three copies of 'Install the secret redactor' differ: "
        + ", ".join(sorted(scripts))
    )


@pytest.mark.parametrize("lane", LANES, ids=lambda lane: lane[0])
def test_each_prompt_asks_the_model_not_to_repeat_credentials(lane):
    model = model_step(lane)
    prompt = (model.get("with") or {}).get("prompt") or model.get("run", "")
    text = " ".join(prompt.split())
    assert "Never repeat a credential from the diff" in text, f"{lane[0]}: no credential rule in the prompt"
    assert "in full or in part" in text


def test_the_install_step_writes_the_shipped_redactor_and_the_hook_settings(tmp_path):
    directory = install(tmp_path / "runner_temp")
    assert (directory / "redact_secrets.py").read_text() == redactor_source()
    settings = json.loads((directory / "settings.json").read_text())
    check_settings_file(settings, directory)
    assert settings["hooks"]["PreToolUse"][0]["hooks"][0]["type"] == "command"


def test_the_install_step_fails_closed_on_a_redactor_that_lets_a_key_through(tmp_path):
    broken = install_script().replace('("whoisxml-api-key", r"at_', '("whoisxml-api-key", r"never_', 1)
    assert broken != install_script(), "mutation did not apply; the pattern moved"
    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", broken],
        env={**os.environ, "RUNNER_TEMP": str(tmp_path)},
        capture_output=True,
        text=True,
    )
    assert proc.returncode != 0
    assert "::error::" in proc.stdout


# ---------------------------------------------------------------------------
# 2. The redactor


@pytest.mark.parametrize("context", sorted(CONTEXTS))
@pytest.mark.parametrize("kind, value", VENDOR, ids=[f"{k}-{i}" for i, (k, _) in enumerate(VENDOR)])
def test_a_vendor_shaped_value_never_survives(redactor, kind, value, context):
    text = CONTEXTS[context](value)
    out = redactor.redact(text)
    assert_gone(out, [value])
    assert f"[REDACTED {kind}]" in out


def labeled_cases():
    v = rand(20)
    return [
        (f"apiKey={v}", v),
        (f"https://api.example.com/v1?apiKey={v}&domainName=example.com", v),
        (f'"password": "{v}"', v),
        (f"password: {v}", v),
        (f"token: {v}", v),
        (f"DB_PASSWORD={v}", v),
        (f"export SERVICE_API_TOKEN='{v}'", v),
        (f"client_secret => '{v}'", v),
        (f"**Password**: `{v}`", v),
        (f"mysql --password={v} -u app", v),
        (f'curl -H "X-Api-Key: {v}" https://api.example.com', v),
        (f"aws_secret_access_key = {v}{rand(20, B64)}", v),
        (f'{{"credentials": "{v}"}}', v),
        (f'secret_key = b"{v}"', v),
        (f"def login(user, password='{v}'):", v),
        (f"passphrase: {v}", v),
        (f'"privateKey": "{v}"', v),
        (f'password: "{v[:3]}7"', v[:3] + "7"),
        (f'password="$3{v}"', v),
        ('"{\\"password\\":\\"' + v + '\\"}"', v),
        (f'mysql --password=\\"{v}\\" -u app', v),
        (f"grep -rn 'DB_PASSWORD=\\\"{v}\\\"' .", v),
    ]


@pytest.mark.parametrize("text, value", labeled_cases(), ids=lambda x: x[:24] if isinstance(x, str) else "")
def test_a_value_given_to_a_credential_name_never_survives(redactor, text, value):
    out = redactor.redact(text)
    assert_gone(out, [value])
    assert "[REDACTED " in out


def letters(n):
    return "".join(RNG.choice(string.ascii_letters) for _ in range(n))


@pytest.mark.parametrize(
    "build",
    [
        lambda v: f"DB_PASSWORD={v}",
        lambda v: f"export API_TOKEN={v}",
        lambda v: f"curl 'https://api.example.com/v1?password={v}&domainName=example.com'",
        lambda v: f"&apiKey={v}",
        lambda v: f"mysql --password={v} -u app",
        lambda v: f"Authorization: Bearer {v}{v}",
        lambda v: f"Authorization: Basic {v[:4]}",
        lambda v: f"password: {v.lower()}",
        lambda v: f"  db_password: {v.lower()}  # prod",
        lambda v: f"- token: {v.upper()}",
        lambda v: f"`password: {v.lower()}`",
        lambda v: f"-password: {v.lower()}",
        lambda v: f"password={v.lower()}",
    ],
    ids=["env-name", "export", "url-query", "url-query-amp", "cli-flag", "bearer", "basic-short",
         "yaml", "yaml-indented-comment", "yaml-list", "yaml-code-span", "yaml-diff-removed", "ini"],
)
def test_an_all_letter_literal_never_survives(redactor, build):
    # No digit, short: where the context makes the value a literal (an
    # environment-style NAME=, a URL query, a flag, an Authorization header),
    # letters alone are enough.
    value = letters(10)
    out = redactor.redact(build(value))
    assert value not in out and "[REDACTED " in out


# Many random values per shape, not one: an exemption that catches a share of
# random keys (a type-name test that accepted digits let 24% through) only
# shows across a sample.
SAMPLE = random.Random(7)
SYMBOLS = string.ascii_letters + string.digits + "!#%&()*+,-./:;<=>?@[]^_{|}~"


def sample(n, alphabet):
    return "".join(SAMPLE.choice(alphabet) for _ in range(n))


@pytest.mark.parametrize(
    "build, length",
    [
        (lambda v: f'api_key: "{v}"', 32),
        (lambda v: f'"client_secret": "{v}"', 40),
        (lambda v: f"API_TOKEN = '{v}'", 24),
        (lambda v: f"secret_key = b'{v}'", 50),
    ],
    ids=["yaml-api-key", "json-client-secret", "python-api-token", "python-bytes"],
)
def test_no_random_key_survives_a_quoted_label(redactor, build, length):
    survivors = [v for v in (sample(length, ALNUM) for _ in range(300)) if v in redactor.redact(build(v))]
    assert not survivors, f"{len(survivors)} of 300 random keys passed unredacted"


@pytest.mark.parametrize("build", [lambda v: f'password: "{v}"', lambda v: f"DB_PASSWORD='{v}'"], ids=["yaml", "env"])
def test_a_generated_password_survives_only_as_a_template(redactor, build):
    # Symbols included. The one exemption a random password can hit is a value
    # that is itself a whole template or placeholder (`{...}`, `<...>`).
    for value in (sample(SAMPLE.randint(12, 32), SYMBOLS) for _ in range(500)):
        if value in redactor.redact(build(value)):
            assert redactor.REFERENCE.search(value), "a generated password passed unredacted"


@pytest.mark.parametrize(
    "text, value",
    [
        ("JWT_SECRET=supersecretjwtsigningkey", "supersecretjwtsigningkey"),
        ('password: "mysecretpassword"', "mysecretpassword"),
        ('passphrase: "correct horse battery staple"', "correct horse battery staple"),
        ('password: "Hunter2Hunter"', "Hunter2Hunter"),
        ("Authorization: Bearer supersecrettokenvalue", "supersecrettokenvalue"),
        ("DB_PASSWORD=abc\\defghijkl", "defghijkl"),
        ("JWT_SECRET=super-secret-jwt-key", "super-secret-jwt-key"),
        ('password: "my-secret-password"', "my-secret-password"),
    ],
    ids=["word-inside-value", "word-inside-quoted", "passphrase", "camel-with-digit", "header-word-inside", "backslash",
         "hyphenated-phrase", "hyphenated-quoted"],
)
def test_a_value_that_only_contains_a_credential_word_is_redacted(redactor, text, value):
    # A credential word exempts a value only as a whole part of a name
    # (`db_password`, `accessToken`), never as a substring of a secret.
    assert value not in redactor.redact(text)


def code_literal_keys():
    body = [sample(64, ALNUM + "+/") for _ in range(3)] + [sample(40, ALNUM + "+/") + "=="]
    js = "const KEY = '-----BEGIN RSA PRIVATE KEY-----\\n' +\n" + "".join(f"  '{x}\\n' +\n" for x in body) + "  '-----END RSA PRIVATE KEY-----\\n';"
    return body, {
        "js-concatenation": js,
        "python-implicit-concatenation": 'KEY = (\n    "-----BEGIN PRIVATE KEY-----\\n"\n' + "".join(f'    "{x}\\n"\n' for x in body) + '    "-----END PRIVATE KEY-----\\n"\n)',
        "java-concatenation": 'String KEY = "-----BEGIN EC PRIVATE KEY-----\\n"\n' + "".join(f'    + "{x}\\n"\n' for x in body) + '    + "-----END EC PRIVATE KEY-----";',
        "json-list": '{"key": ["-----BEGIN PRIVATE KEY-----", ' + ", ".join(f'"{x}"' for x in body) + ', "-----END PRIVATE KEY-----"]}',
        "shell-continuation": 'KEY="-----BEGIN PRIVATE KEY-----\\\n' + "".join(f"{x}\\\n" for x in body) + '-----END PRIVATE KEY-----"',
        "js-removed-diff-lines": "\n".join("-" + line for line in js.splitlines()),
        "js-cut-short": "\n".join(js.splitlines()[:-1]) + "\n// end of fixture",
        "php-dot-concatenation": '$key = "-----BEGIN PRIVATE KEY-----\\n" .\n'
        + "".join(f'    "{x}\\n" .\n' for x in body)
        + '    "-----END PRIVATE KEY-----\\n";',
        "perl-dot-concatenation": "my $k = '-----BEGIN PRIVATE KEY-----' . \"\\n\" .\n"
        + "".join(f"  '{x}' . \"\\n\" .\n" for x in body)
        + "  '-----END PRIVATE KEY-----';",
        "lua-concatenation": 'local k = "-----BEGIN PRIVATE KEY-----\\n" ..\n'
        + "".join(f'  "{x}\\n" ..\n' for x in body)
        + '  "-----END PRIVATE KEY-----"',
        "vb-concatenation": 'Dim k = "-----BEGIN PRIVATE KEY-----" & vbLf &\n'
        + "".join(f'  "{x}" & vbLf &\n' for x in body)
        + '  "-----END PRIVATE KEY-----"',
        "php-cut-short": '$key = "-----BEGIN PRIVATE KEY-----\\n" .\n'
        + "".join(f'    "{x}\\n" .\n' for x in body[:3])
        + '    "' + body[3] + '";',
    }


@pytest.mark.parametrize("shape", sorted(code_literal_keys()[1]))
def test_a_private_key_written_as_code_never_survives(redactor, shape):
    body, shapes = code_literal_keys()
    text = shapes[shape]
    sink = __import__("io").BytesIO()
    redactor.stream(__import__("io").BytesIO(text.encode()), sink)
    for out in (redactor.redact(text), sink.getvalue().decode()):
        assert_gone(out, body)
        assert "[REDACTED private-key]" in out


def test_url_passwords_and_authorization_values_never_survive(redactor):
    password, token, basic = rand(18), rand(40, B64URL), rand(32, B64)
    cases = {
        f"git remote add origin https://deploy:{password}@github.com/o/r.git": "url-password",
        f"DATABASE_URL=postgresql://app:{password}@db.internal:5432/app": "url-password",
        f"Authorization: Bearer {token}": "credential",
        f"-H 'Authorization: token {token}'": "credential",
        f"Authorization: Basic {basic}": "credential",
        f'headers = {{"Authorization": "Bearer {token}"}}': "credential",
    }
    for text, kind in cases.items():
        out = redactor.redact(text)
        assert_gone(out, [password, token, basic])
        assert f"[REDACTED {kind}]" in out, out


def pem_block(kind="RSA PRIVATE KEY", lines=4, headers=""):
    body = "\n".join(rand(64, B64) for _ in range(lines - 1)) + "\n" + rand(24, B64) + "=="
    return f"-----BEGIN {kind}-----\n{headers}{body}\n-----END {kind}-----", body.splitlines()


@pytest.mark.parametrize(
    "kind",
    ["RSA PRIVATE KEY", "OPENSSH PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "PGP PRIVATE KEY BLOCK"],
)
def test_a_whole_private_key_block_never_survives(redactor, kind):
    block, lines = pem_block(kind)
    text = f"config/deploy_key adds:\n```\n{block}\n```\nRemove it and rotate the key."
    out = redactor.redact(text)
    assert_gone(out, lines)
    assert out == "config/deploy_key adds:\n```\n[REDACTED private-key]\n```\nRemove it and rotate the key."


def test_a_private_key_quoted_in_part_never_survives(redactor):
    _, lines = pem_block()
    headers = "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC," + rand(32, UPPER) + "\n\n"
    cut = "-----BEGIN RSA PRIVATE KEY-----\n" + headers + "\n".join(lines[:2]) + "\n" + lines[2][:20] + "...\n\nThe key above is committed in plain text."
    out = redactor.redact(cut)
    assert_gone(out, lines[:2] + [lines[2][:20]])
    assert out == "[REDACTED private-key]\n\nThe key above is committed in plain text."


def test_a_json_escaped_private_key_never_survives(redactor):
    block, lines = pem_block("PRIVATE KEY")
    whole = json.dumps({"body": f"key:\n{block}\ndone"})
    cut = '{"body": "-----BEGIN PRIVATE KEY-----\\n' + lines[0] + "\\n" + lines[1][:30] + '"}'
    for text in (whole, cut):
        out = redactor.redact(text)
        assert_gone(out, [lines[0], lines[1][:30]])
        assert "[REDACTED private-key]" in out
        json.loads(out)  # still valid JSON


@pytest.mark.parametrize("prefix", ["-", "+", " ", "> ", "> -"], ids=["removed", "added", "context", "quoted", "quoted-removed"])
@pytest.mark.parametrize("whole", [True, False], ids=["with-end", "cut-short"])
def test_a_private_key_in_a_diff_or_quote_never_survives(redactor, prefix, whole):
    # A key a PR removes reaches the model as `-MII...` diff lines, and a
    # model quotes it as `> MII...`: in the log Codex streams, and in a review.
    block, lines = pem_block()
    if not whole:
        block = "\n".join(block.splitlines()[:-1])
    text = "\n".join(prefix + line for line in block.splitlines()) + "\n\nThe key above is committed.\n"
    out = redactor.redact(text)
    sink = __import__("io").BytesIO()
    redactor.stream(__import__("io").BytesIO(text.encode()), sink)
    for result in (out, sink.getvalue().decode()):
        assert_gone(result, lines)
        assert "[REDACTED private-key]" in result and "The key above is committed." in result


def test_an_identifier_after_a_named_header_survives(redactor):
    # A long word is no key material: random base64 that long has a digit,
    # `+` or `/`, and an identifier has none.
    text = "`load()` checks for `-----BEGIN PRIVATE KEY-----`\n`parsePrivateKeyFromPem` never validates the body."
    assert redactor.redact(text) == text


def test_naming_a_private_key_line_keeps_the_prose(redactor):
    # A header named with no key after it is no secret, and stays as written.
    text = "Line 1 adds `-----BEGIN RSA PRIVATE KEY-----`: a private key is committed."
    assert redactor.redact(text) == text


@pytest.mark.parametrize(
    "text",
    [
        "`parse_key()` checks for `-----BEGIN PRIVATE KEY-----` on line 10, but line 14 never checks for "
        "`-----END PRIVATE KEY-----`, so a truncated file is accepted.",
        "regression: certs/load.py:10 - `-----BEGIN RSA PRIVATE KEY-----` headers are no longer tested; "
        "regression: certs/load.py:22 - the retry loop never backs off; "
        "regression: certs/load.py:30 - the `-----END RSA PRIVATE KEY-----` check has no test",
        "```suggestion\nif line.startswith(\"-----BEGIN PRIVATE KEY-----\"):\n    in_key = True\n"
        "elif line.startswith(\"-----END PRIVATE KEY-----\"):\n    in_key = False\n```",
    ],
    ids=["inline-comment", "verdict-three-findings", "suggestion-block"],
)
def test_text_between_two_named_key_headers_survives(redactor, text):
    # Only a key body between BEGIN and END is a key: findings a review names
    # around the two headers must reach the PR, in every mode.
    assert redactor.redact(text) == text
    sink = __import__("io").BytesIO()
    redactor.stream(__import__("io").BytesIO(text.encode()), sink)
    assert sink.getvalue().decode() == text


# Code and prose that name a credential without holding one, identifiers,
# digests, and the lanes' own protocol lines: all pass byte for byte.
ORDINARY = [
    "def login(token: str, password: Optional[str] = None) -> Session:",
    'token = os.environ["GITHUB_TOKEN"]',
    "api_key = settings.WHOISXML_API_KEY",
    "password = getpass.getpass()",
    "self.api_key = api_key",
    "token = jwt.encode(payload, key, algorithm='HS256')",
    "credentials = service_account.Credentials.from_service_account_file(path)",
    "password_hash = bcrypt.hashpw(password.encode(), salt)",
    "if token == expected_token_value_123:",
    "if password != confirm_password:",
    "while (auth_token := next_token()) is not None:",
    "max_tokens=4096, num_tokens: 12, tokenizer: cl100k",
    "const apiKey: string = process.env.API_KEY ?? '';",
    "apiKey?: string;",
    "private readonly apiKey: ApiKeyProvider;",
    "TOKEN=$(gh auth token)",
    "password: ${DB_PASSWORD}",
    "GH_TOKEN: ${{ github.token }}",
    "anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}",
    "secret: true",
    "token_type: bearer",
    '"tokenId": 1234567890,',
    "access_token_expires_in: 3600",
    "apiKey=YOUR_API_KEY",
    "?apiKey=YOUR_API_KEY&domainName=example.com",
    "API_KEY=YOUR_API_KEY",
    "TOKEN=None",
    "login(user=user, password=password)",
    "PASSWORD = default_pw",
    "export GH_TOKEN=$(gh auth token)",
    '"password": "password",',
    "the shapes `apiKey=`, `\"password\": `, `DB_PASSWORD=` and `--password=`, each in its own code span",
    "fetch(url, { credentials: 'include' })",
    "credentials: 'same-origin',",
    "credentials: 'omit'",
    "client(aws_secret_access_key=aws_secret_access_key, personal_access_token=personal_access_token)",
    "token: 'bearer' | 'basic'",
    'token: "AuthToken"',
    "secret: generatedSessionSecret",
    "'password' => 'required|string|min:8|confirmed'",
    "run the basic tests/integration/test_auth.py suite",
    "Authorization: see src/middleware/authorization.ts",
    "token: refresh",
    "secret: disabled",
    "token: 'none'",
    'secret: "yes"',
    'the "password=" field and the "token" field',
    "`password: \"` + value + `\"` builds it",
    "password: ''",
    'token: "{token}"',
    'password="%s" % pw',
    "  token: string",
    "  token: JwtPayload",
    "    password: SecretStr",
    "token: string;",
    "token = response",
    "Authorization: Bearer token",
    "Authorization: Bearer YOUR_TOKEN",
    "send a Bearer token in the header",
    "password: '********'",
    "token: xxxxxxxxxxxx",
    "password: Optional[str]",
    'headers["Authorization"] = f"Bearer {token}"',
    "Authorization: Bearer ${TOKEN}",
    "Bearer authentication is required on every endpoint.",
    "the token: refresh logic is untested",
    "Password: rotate it quarterly.",
    "ssh://git@github.com/example-org/example-repo.git",
    "https://example.com:8443/path?query=1",
    "postgres://localhost:5432/app",
    "created_at_timestamp_in_milliseconds_utc = 0",
    "selftest/test_claude_review_lost_findings_guard.sh",
    "at_Q7fXp (sha256 1a2b3c4d) is the key, by its first 8 characters",
    "commit 2adc3787d0b0a4f6f0b1c2d3e4f5a6b7c8d9e0f1",
    "sha256: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    "uuid 123e4567-e89b-12d3-a456-426614174000",
    '"integrity": "sha512-3NGPEUj+VTMQAQ0vaUUQtrce6rNb9a4XhY8QKIOLUp9mDkdbwrrjjD9oMKcDpcLhFKqZdTc02RBUo55GrbY9CA=="',
    "uses: anthropics/claude-code-action@a26b07d8c778b0c43f64618e5fd29fd0f8af72e8 # v1.0.250",
    "/task-admin-dashboard-overview-page-v2 and risk-ant-colony-optimization-v2",
    "disk_live_statusreportforday2",
    "Flagged 2 issues inline — see comments.",
    "No issues found. Diff is small and contained.",
    "Skipped: changes are docs-only / out of review scope.",
    "no regressions found",
    "regression: src/policy.ts:78 — no test exercises the new error path",
    "regression: src/auth.py:42 - token: refresh path not tested",
    "VERDICT: CLEAN",
    "VERDICT: REGRESSION",
    "- [P1] the retry loop never backs off — src/client.ts:41",
    "[link](https://example.com/docs#api-key) ![badge](https://img.shields.io/x.svg)",
]


@pytest.mark.parametrize("text", ORDINARY)
def test_ordinary_text_passes_unchanged(redactor, text):
    assert redactor.redact(text) == text


@pytest.mark.parametrize(
    "path",
    [
        WORKFLOWS / "claude-review.yml",
        WORKFLOWS / "claude-adversarial-review.yml",
        WORKFLOWS / "codex-review.yml",
        SCRIPTS / "codex-verdict.mjs",
        SCRIPTS / "unaddressed-findings.sh",
    ],
    ids=lambda p: p.name,
)
def test_the_lanes_own_code_passes_unchanged(redactor, path):
    # Thousands of lines of real workflow code and prose, the redactor's own
    # source included, the way a review of this repo would quote them.
    text = path.read_text()
    assert redactor.redact(text) == text


def test_redaction_is_idempotent(redactor):
    texts = [CONTEXTS[c](v) for c in CONTEXTS for _, v in VENDOR]
    texts += [t for t, _ in labeled_cases()] + [pem_block()[0]] + ORDINARY
    for text in texts:
        once = redactor.redact(text)
        assert redactor.redact(once) == once


def test_the_modes_agree(redactor, tmp_path):
    directory = install(tmp_path / "runner_temp")
    script = str(directory / "redact_secrets.py")
    planted = [v for _, v in VENDOR]
    whole, whole_lines = pem_block()
    cut = "-----BEGIN PRIVATE KEY-----\n" + rand(64, B64) + "\n" + rand(30, B64) + "...\n\nThat key is committed."
    text = "\n".join(CONTEXTS["prose"](v) for v in planted) + "\n" + "\n".join(ORDINARY) + "\n"
    text += f"block:\n{whole}\nafter\n{cut}\nlast line\n"
    planted += whole_lines
    expected = redactor.redact(text)
    assert "[REDACTED private-key]\nafter" in expected and "[REDACTED private-key]\n\nThat key" in expected
    filtered = subprocess.run(["python3", script], input=text.encode(), capture_output=True, check=True)
    assert filtered.stdout.decode() == expected
    in_place = tmp_path / "comment.md"
    in_place.write_text(text)
    subprocess.run(["python3", script, str(in_place)], check=True)
    assert in_place.read_text() == expected
    # Check mode: names the file and the kinds, never a value; 1 when found.
    clean = tmp_path / "clean.md"
    clean.write_text(expected)
    found = subprocess.run(["python3", script, "--check", str(clean), str(tmp_path / "dirty.md")], capture_output=True, text=True, input="")
    assert found.returncode == 2, "an unreadable file must not read as clean or as found"
    dirty = tmp_path / "dirty.md"
    dirty.write_text(text)
    found = subprocess.run(["python3", script, "--check", str(clean), str(dirty)], capture_output=True, text=True)
    assert found.returncode == 1
    assert found.stdout.startswith(f"{dirty}: ") and str(clean) not in found.stdout
    assert "whoisxml-api-key" in found.stdout
    assert_gone(found.stdout + found.stderr, planted)
    assert subprocess.run(["python3", script, "--check", str(clean)], capture_output=True).returncode == 0


def test_the_filter_streams_line_by_line(tmp_path):
    # A log fed through the filter stays live: a line comes out before the
    # next one goes in. A private-key block is held until it ends.
    directory = install(tmp_path / "runner_temp")
    key = "at_" + rand(29)
    proc = subprocess.Popen(
        ["python3", str(directory / "redact_secrets.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )
    try:
        proc.stdin.write(f"first line {key}\n".encode())
        proc.stdin.flush()
        assert proc.stdout.readline() == b"first line [REDACTED whoisxml-api-key]\n"
        block, lines = pem_block()
        first, rest = block.split("\n", 1)
        proc.stdin.write((first + "\n").encode())
        proc.stdin.flush()
        proc.stdin.write((rest + "\nnext line\n").encode())
        proc.stdin.flush()
        assert proc.stdout.readline() == b"[REDACTED private-key]\n"
        assert proc.stdout.readline() == b"next line\n"
    finally:
        proc.stdin.close()
        proc.wait(timeout=10)
    assert proc.returncode == 0


def test_text_that_is_not_utf8_passes_through(tmp_path):
    directory = install(tmp_path / "runner_temp")
    key = "at_" + rand(29)
    raw = b"\xff\xfe binary-ish " + key.encode() + b" \xc3\x28 end\n"
    out = subprocess.run(["python3", str(directory / "redact_secrets.py")], input=raw, capture_output=True, check=True).stdout
    assert key.encode() not in out
    assert out.startswith(b"\xff\xfe binary-ish [REDACTED whoisxml-api-key]")


def placeholders(redactor):
    kinds = {kind for kind, _ in redactor.TOKENS} | {"private-key", "url-password", "credential", "secret-value"}
    return sorted(f"[REDACTED {kind}]" for kind in kinds)


def test_no_placeholder_matches_a_marker_the_merge_gates_read(redactor):
    # unaddressed-findings.sh's FINDING_RE, CLEAN_RE and SEVERITY_RE, read from
    # the shipped script and applied the way it applies them (jq's test()).
    script = (SCRIPTS / "unaddressed-findings.sh").read_text()
    names = ("_NOT_EMPTY", "_REGRESSION_MARKER", "FINDING_RE", "CLEAN_RE", "SEVERITY_RE")
    probe = "\n".join(line for line in script.splitlines() if line.split("=", 1)[0] in names)
    for name in names:
        assert re.search(rf"^{name}=", probe, re.M), f"{name} moved out of unaddressed-findings.sh"
    for placeholder in placeholders(redactor):
        body = f"Line 12 commits {placeholder} in plain text."
        result = subprocess.run(
            ["bash", "-c", probe + '\nfor re in "$FINDING_RE" "$CLEAN_RE" "$SEVERITY_RE"; do jq -n --arg re "$re" --arg s "$1" \'$s | test($re; "i")\'; done', "_", body],
            capture_output=True,
            text=True,
            check=True,
        )
        assert result.stdout.split() == ["false", "false", "false"], (placeholder, result.stdout)


def test_a_redacted_codex_verdict_classifies_as_before(redactor, tmp_path):
    key = "at_" + rand(29)
    verdicts = {
        "clean": f"No regressions found; config.py still carries {key}.\nVERDICT: CLEAN",
        "regression": f"regression: config.py:12 - the fallback key {key} has no test\nVERDICT: REGRESSION",
    }
    for want, verdict in verdicts.items():
        states = []
        for text in (verdict, redactor.redact(verdict)):
            path = tmp_path / "verdict.txt"
            path.write_text(text + "\n")
            out = tmp_path / "out"
            out.write_text("")
            subprocess.run(
                ["node", str(SCRIPTS / "codex-verdict.mjs")],
                env={**os.environ, "VERDICT_FILE": str(path), "FAIL_ON_REGRESSION": "false", "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": ""},
                capture_output=True,
                check=True,
            )
            states.append(re.search(r"^verdict_state=(.*)$", out.read_text(), re.M).group(1))
        assert states == [want, want], (want, states)


# ---------------------------------------------------------------------------
# 3. The hook


def review_model_step():
    return find(REVIEW, step_id="claude")


def check_hook_wiring(with_):
    args = with_.get("claude_args", "")
    assert SETTINGS_ARG in args, "claude_args no longer passes the redaction hook's settings file"
    assert "settings" not in with_, (
        "the action's `settings` input lands in user settings, which a base branch's disableAllHooks overrides"
    )
    tools = re.search(r'--allowedTools\s+"([^"]*)"', args).group(1).split(",")
    assert INLINE_TOOL in tools, "the hook's matcher must be the inline-comment tool the allowlist grants"


def check_settings_file(settings, directory):
    assert settings.get("disableAllHooks") is False, "without it a base branch's disableAllHooks: true turns the hook off"
    (entry,) = settings["hooks"]["PreToolUse"]
    assert entry["matcher"] == INLINE_TOOL
    assert [h["command"] for h in entry["hooks"]] == [f"python3 {directory}/redact_secrets.py --hook || exit 2"]


def test_the_review_step_passes_the_hook_settings_and_nothing_else_does():
    check_hook_wiring(review_model_step().get("with") or {})
    for lane in (ADVERSARIAL,):
        tools = re.search(r'--allowedTools\s+"([^"]*)"', model_step(lane)["with"]["claude_args"]).group(1)
        assert "mcp__" not in tools, f"{lane[0]}: a model with an MCP posting tool needs the hook too"


def hook_command(directory):
    settings = json.loads((directory / "settings.json").read_text())
    return settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"]


def run_hook(command, event, path=None):
    """Run the hook command the way the CLI does: a shell, the event on stdin."""
    env = {**os.environ}
    if path is not None:
        env["PATH"] = path
    stdin = event if isinstance(event, str) else json.dumps(event)
    return subprocess.run([shutil.which("bash"), "-c", command], input=stdin, env=env, capture_output=True, text=True)


def hook_event(tool_input):
    return {
        "session_id": "s",
        "transcript_path": "/dev/null",
        "cwd": "/tmp",
        "hook_event_name": "PreToolUse",
        "tool_name": INLINE_TOOL,
        "tool_input": tool_input,
        "tool_use_id": "toolu_1",
    }


def test_the_hook_redacts_the_body_and_leaves_everything_else(tmp_path):
    command = hook_command(install(tmp_path / "runner_temp"))
    key, token = "at_" + rand(29), "ghp_" + rand(36)
    tool_input = {
        "path": "config.py",
        "line": 12,
        "startLine": 10,
        "side": "RIGHT",
        "commit_id": "2adc3787d0b0a4f6f0b1c2d3e4f5a6b7c8d9e0f1",
        "confirmed": True,
        "body": f"Lines 10-12 commit `{key}` and {token}.\n```suggestion\nKEY = os.environ['WHOISXML_API_KEY']\n```",
    }
    result = run_hook(command, hook_event(tool_input))
    assert result.returncode == 0, result.stderr
    assert_gone(result.stdout + result.stderr, [key, token])
    output = json.loads(result.stdout)
    assert output == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": {
                **tool_input,
                "body": "Lines 10-12 commit `[REDACTED whoisxml-api-key]` and [REDACTED github-token].\n"
                "```suggestion\nKEY = os.environ['WHOISXML_API_KEY']\n```",
            },
        }
    }, "the hook must rewrite the input only, and leave the decision to the allowlist"


def test_the_hook_prints_nothing_for_a_clean_call(tmp_path):
    command = hook_command(install(tmp_path / "runner_temp"))
    result = run_hook(command, hook_event({"path": "a.py", "line": 1, "body": "`token: str` is never validated."}))
    assert (result.returncode, result.stdout) == (0, "")


@pytest.mark.parametrize(
    "event",
    ["not json", json.dumps({"tool_input": "a string"}), json.dumps({"no_tool_input": {}}), ""],
    ids=["not-json", "input-not-an-object", "no-input", "empty"],
)
def test_the_hook_blocks_a_call_it_cannot_read(tmp_path, event):
    command = hook_command(install(tmp_path / "runner_temp"))
    result = run_hook(command, event)
    assert (result.returncode, result.stdout) == (2, "")


def test_the_hook_blocks_the_call_without_a_redactor_or_a_python(tmp_path):
    directory = install(tmp_path / "runner_temp")
    command = hook_command(directory)
    event = hook_event({"path": "a.py", "line": 1, "body": "at_" + rand(29)})
    empty = tmp_path / "empty-path"
    empty.mkdir()
    result = run_hook(command, event, path=str(empty))
    assert (result.returncode, result.stdout) == (2, ""), "no python3 on PATH must block, not let the call through"
    (directory / "redact_secrets.py").unlink()
    result = run_hook(command, event)
    assert (result.returncode, result.stdout) == (2, "")


def test_the_hook_without_its_exit_2_lets_a_call_through(tmp_path):
    # Negative control: a hook that fails any other way does not block.
    command = hook_command(install(tmp_path / "runner_temp"))
    mutant = command.replace(" || exit 2", "")
    assert mutant != command
    empty = tmp_path / "empty-path"
    empty.mkdir()
    result = run_hook(mutant, hook_event({"path": "a.py", "line": 1, "body": "x"}), path=str(empty))
    assert result.returncode not in (0, 2)


# ---------------------------------------------------------------------------
# 4. The posting steps, as shipped, against a stub gh

GH_STUB = r"""#!/usr/bin/env bash
n=$(find "$GH_CALLS" -name 'call.*' | wc -l | tr -d ' ')
printf '%s\0' "$@" > "$GH_CALLS/call.$n"
prev=""
for arg in "$@"; do
  if [ "$prev" = "--body-file" ]; then cp "$arg" "$GH_CALLS/body.$n"; fi
  prev="$arg"
done
if [ "$1 $2" = "pr comment" ]; then
  if [ "${GH_COMMENT_FAIL:-0}" = "1" ]; then
    echo "HTTP 503: No server is currently available to service your request" >&2
    exit 1
  fi
  echo "https://github.com/o/r/pull/478#issuecomment-1"
  exit 0
fi
if [ "$1" = "api" ]; then
  for arg in "$@"; do
    case "$arg" in
      */pulls/*/comments*|*/issues/*/comments*)
        if [ "${GH_LIST_FAIL:-0}" = "1" ]; then echo '{"message":"Server Error"}'; exit 1; fi
        case "$arg" in
          */pulls/*) cat "${GH_PULLS_JSON:-/dev/null}" ;;
          *) cat "${GH_ISSUES_JSON:-/dev/null}" ;;
        esac
        exit 0
        ;;
    esac
  done
fi
echo "stub gh: unexpected call: $*" >&2
exit 1
"""


class Harness:
    """Runs shipped steps the way the runner does, against stub gh/git/codex."""

    def __init__(self, tmp_path, with_redactor=True):
        tmp_path.mkdir(parents=True, exist_ok=True)
        self.root = tmp_path
        self.bin = tmp_path / "bin"
        self.bin.mkdir()
        write_executable(self.bin / "gh", GH_STUB)
        write_executable(self.bin / "sleep", "#!/usr/bin/env bash\nexit 0\n")
        write_executable(self.bin / "git", "#!/usr/bin/env bash\nexit 0\n")
        self.calls = tmp_path / "calls"
        self.calls.mkdir()
        self.runner_temp = tmp_path / "runner_temp"
        self.runner_temp.mkdir()
        if with_redactor:
            install(self.runner_temp)
        self.output = tmp_path / "github_output"
        self.output.write_text("")
        self.summary = tmp_path / "step_summary"
        self.summary.write_text("")
        self.logs = []

    def run(self, step, values, extra_env=None, script=None):
        env = {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.root),
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_STEP_SUMMARY": str(self.summary),
            "GITHUB_RUN_ID": "1",
            "GH_CALLS": str(self.calls),
        }
        for name, value in (step.get("env") or {}).items():
            def evaluate(match):
                assert match.group(1) in values, f"no fixture value for {match.group(0)}"
                return values[match.group(1)]

            env[name] = EXPRESSION.sub(evaluate, str(value))
        env.update(extra_env or {})
        path = self.root / f"step{len(self.logs)}.sh"
        path.write_text(script if script is not None else shipped(step))
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(path)],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
        )
        self.logs.append(proc.stdout + proc.stderr)
        return proc

    def bodies(self):
        return [p.read_text() for p in sorted(self.calls.glob("body.*"))]

    def posts(self):
        return [
            p for p in sorted(self.calls.glob("call.*")) if p.read_bytes().split(b"\0")[:2] == [b"pr", b"comment"]
        ]

    def everything(self):
        """Every surface a value could leave the job by."""
        return "\n".join(self.bodies() + self.logs + [self.summary.read_text()])


VALUES = {
    "github.token": "stub-token",
    "github.repository": "o/r",
    "github.event.pull_request.number": "478",
    "github.server_url": "https://github.example",
    "github.run_id": "1",
    "steps.clock.outputs.started_at": "2026-10-22T20:00:00Z",
    "steps.caller.outputs.changed != 'false' && 'github-actions[bot]' || 'claude[bot]'": "claude[bot]",
    "inputs.max_budget_usd": "3",
}


def planted_message():
    """A final message holding one value of every shape, the ways a model quotes them."""
    values = [v for _, v in VENDOR]
    password, block = rand(20), pem_block()
    text = "Flagged 2 issues inline — see comments.\n\n" + "\n".join(
        f"- {CONTEXTS['code span'](v)}" for v in values
    )
    text += f'\n- `DB_PASSWORD={password}` and\n```\n{block[0]}\n```\n'
    return text, values + [password] + block[1]


def transcript(tmp_path, result, denials=()):
    path = tmp_path / "claude-execution-output.json"
    path.write_text(
        json.dumps(
            [
                {"type": "system", "subtype": "init"},
                {"type": "assistant", "message": {"content": [{"type": "text", "text": "Reading."}]}},
                {
                    "type": "result",
                    "subtype": "success",
                    "is_error": False,
                    "num_turns": 4,
                    "result": result,
                    "permission_denials": list(denials),
                },
            ]
        )
    )
    return path


SUMMARY = (REVIEW, "summary")
VERDICT = (ADVERSARIAL, "verdict")


@pytest.mark.parametrize("lane, step_id", [SUMMARY, VERDICT], ids=["review-summary", "adversarial-verdict"])
@pytest.mark.parametrize("comment_api", ["healthy", "down"])
def test_a_claude_lane_posts_and_logs_its_final_message_redacted(tmp_path, lane, step_id, comment_api):
    harness = Harness(tmp_path)
    message, planted = planted_message()
    values = {**VALUES, "steps.claude.outputs.execution_file": str(transcript(tmp_path, message)), "steps.claude.outcome": "success"}
    proc = harness.run(find(lane, step_id=step_id), values, {"GH_COMMENT_FAIL": "1" if comment_api == "down" else "0"})
    assert_gone(harness.everything(), planted)
    if comment_api == "healthy":
        assert proc.returncode == 0, harness.logs[-1]
        (body,) = harness.bodies()
        assert "[REDACTED whoisxml-api-key]" in body and "[REDACTED private-key]" in body
        assert body.startswith("Flagged 2 issues inline — see comments.")
    else:
        assert "[REDACTED whoisxml-api-key]" in harness.logs[-1], "the log copy of an unposted message is redacted, not dropped"
    if step_id == "summary":
        written = Path(re.search(r"^file=(.*)$", harness.output.read_text(), re.M).group(1)).read_text()
        assert_gone(written, planted)
        assert written.startswith("Flagged 2 issues inline"), "the guard still reads the claim from the redacted file"


@pytest.mark.parametrize("lane, step_id", [SUMMARY, VERDICT], ids=["review-summary", "adversarial-verdict"])
def test_a_claude_lane_without_the_redactor_posts_nothing_and_fails(tmp_path, lane, step_id):
    harness = Harness(tmp_path, with_redactor=False)
    message, planted = planted_message()
    values = {**VALUES, "steps.claude.outputs.execution_file": str(transcript(tmp_path, message)), "steps.claude.outcome": "success"}
    proc = harness.run(find(lane, step_id=step_id), values)
    assert proc.returncode != 0
    assert harness.posts() == []
    assert "::error::" in harness.logs[-1]
    assert_gone(harness.everything(), planted)
    if step_id == "summary":
        written = re.search(r"^file=(.*)$", harness.output.read_text(), re.M).group(1)
        assert Path(written).read_text() == "", "the guard must find nothing unredacted to read"


def denied_inline(body, path="config.py", line=12):
    return {"tool_name": INLINE_TOOL, "tool_use_id": "tu_1", "tool_input": {"path": path, "line": line, "body": body}}


def run_review_tail(harness, tmp_path, message, denials, inline_json="[]", guard_script=None, before_guard=None):
    """The summary step, then the lost-findings guard, as the runner runs them."""
    execution = transcript(tmp_path, message, denials)
    values = {**VALUES, "steps.claude.outputs.execution_file": str(execution), "steps.claude.outcome": "success"}
    pulls = tmp_path / "pulls.json"
    pulls.write_text(inline_json)
    harness.run(find(REVIEW, step_id="summary"), values)
    if before_guard is not None:
        before_guard()
    values["steps.summary.outputs.file"] = re.search(r"^file=(.*)$", harness.output.read_text(), re.M).group(1)
    return harness.run(find(REVIEW, step_id="guard"), values, {"GH_PULLS_JSON": str(pulls)}, script=guard_script)


def test_the_guard_posts_and_logs_recovered_findings_redacted(tmp_path):
    harness = Harness(tmp_path)
    key, token = "at_" + rand(29), "ghp_" + rand(36)
    finding = f"Line 12 commits the WhoisXML key `{key}` and the token {token} in plain text."
    proc = run_review_tail(harness, tmp_path, "Flagged 1 issue inline — see comments.", [denied_inline(finding)])
    assert proc.returncode == 0, harness.logs[-1]
    fallback = [b for b in harness.bodies() if "lost-findings" in b]
    assert len(fallback) == 1, harness.logs[-1]
    assert "config.py:12" in fallback[0] and "[REDACTED whoisxml-api-key]" in fallback[0]
    assert "permission denied for " + INLINE_TOOL in harness.logs[-1]
    assert "[REDACTED github-token]" in harness.logs[-1], "the denial digest prints the redacted input"
    assert_gone(harness.everything(), [key, token])


def test_the_guard_redacts_a_labeled_value_in_a_denied_input(tmp_path):
    # The digest serializes each denied input, and serialized, a quote inside
    # a value reads `\"`: the inputs are redacted as decoded strings first.
    harness = Harness(tmp_path)
    password = letters(6) + "7"
    denied = [
        {"tool_name": "Bash", "tool_use_id": "b1", "tool_input": {"command": f"grep -rn 'DB_PASSWORD=\"{password}\"' ."}},
        denied_inline(f'config.py sets password = "{password}"'),
    ]
    run_review_tail(harness, tmp_path, "No issues found.", denied)
    assert "permission denied for Bash" in harness.logs[-1]
    assert_gone(harness.everything(), [password])


def test_the_guard_redacts_a_key_before_it_cuts_a_denial_line(tmp_path):
    harness = Harness(tmp_path)
    key = "at_" + rand(29)
    # The key straddles the 400-character cut: cut first, a fragment no
    # pattern matches would be printed.
    body = "x" * (400 - len("permission denied for " + INLINE_TOOL + ': {"path":"config.py","line":12,"body":"') - 10) + key
    run_review_tail(harness, tmp_path, "No issues found.", [denied_inline(body)])
    assert_gone(harness.everything(), [key])
    assert "permission denied for " + INLINE_TOOL in harness.logs[-1]
    assert key[:10] not in harness.logs[-1], "the line was cut before it was redacted"


def landed_redacted_comment(tmp_path, guard_script=None):
    """A review whose one inline comment held a key: the hook redacted it, it
    landed redacted, and the summary over-claims. Returns the harness."""
    harness = Harness(tmp_path)
    key = "at_" + rand(29)
    body = f"config.py:12 commits `{key}` in plain text."
    execution = tmp_path / "claude-execution-output.json"
    execution.write_text(
        json.dumps(
            [
                {"type": "system", "subtype": "init"},
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "tool_use", "id": "tu_1", "name": INLINE_TOOL,
                                             "input": {"path": "config.py", "line": 12, "body": body}}]},
                },
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tu_1", "content": "ok"}]}},
                {"type": "result", "subtype": "success", "is_error": False, "num_turns": 3,
                 "result": "Flagged 2 issues inline — see comments.", "permission_denials": []},
            ]
        )
    )
    posted = [{"user": {"login": "claude[bot]"}, "created_at": "2026-10-22T20:05:00Z", "path": "config.py", "line": 12,
               "body": "config.py:12 commits `[REDACTED whoisxml-api-key]` in plain text."}]
    pulls = tmp_path / "pulls.json"
    pulls.write_text(json.dumps(posted))
    values = {**VALUES, "steps.claude.outputs.execution_file": str(execution), "steps.claude.outcome": "success"}
    harness.run(find(REVIEW, step_id="summary"), values)
    values["steps.summary.outputs.file"] = re.search(r"^file=(.*)$", harness.output.read_text(), re.M).group(1)
    proc = harness.run(find(REVIEW, step_id="guard"), values, {"GH_PULLS_JSON": str(pulls)}, script=guard_script)
    return harness, proc, key


def test_the_guard_does_not_re_post_a_redacted_comment_that_landed(tmp_path):
    # The hook rewrote the comment; the transcript keeps what the model
    # wrote. Compared unredacted, the landed comment reads as lost and the
    # guard posts it again as a "recovered" finding.
    harness, proc, key = landed_redacted_comment(tmp_path)
    assert proc.returncode == 0, harness.logs[-1]
    assert not [b for b in harness.bodies() if "lost-findings" in b], "a landed comment was re-posted as lost"
    assert_gone(harness.everything(), [key])


def test_a_guard_comparing_unredacted_bodies_is_caught(tmp_path):
    script = shipped(find(REVIEW, step_id="guard"))
    mutant = re.sub(r' \\\n\s*&& python3 "\$REDACTOR" --json "\$T/calls\.json"', "", script, count=1)
    assert mutant != script, "the comparison's redaction moved; update the mutation"
    harness, proc, key = landed_redacted_comment(tmp_path, guard_script=mutant)
    assert [b for b in harness.bodies() if "lost-findings" in b], "the control no longer re-posts the landed comment"


def test_the_guard_redacts_the_final_message_before_it_cuts_it(tmp_path):
    # The fallback comment carries the final message cut to 8000 bytes; a key
    # straddling the cut, cut first, would leave a fragment no pattern matches.
    harness = Harness(tmp_path)
    key = "at_" + rand(29)
    head = "Flagged 1 issue inline — see comments.\n"
    message = head + "x" * (8000 - len(head.encode()) - 10) + key + "\nmore"
    proc = run_review_tail(harness, tmp_path, message, [denied_inline("the finding")])
    assert proc.returncode == 0, harness.logs[-1]
    (fallback,) = [b for b in harness.bodies() if "lost-findings" in b]
    assert "#### Final message" in fallback
    assert key[:10] not in fallback, "the final message was cut before it was redacted"
    assert_gone(harness.everything(), [key])


def test_the_guard_without_the_redactor_posts_and_prints_nothing(tmp_path):
    harness = Harness(tmp_path)
    key = "at_" + rand(29)
    redactor_file = harness.runner_temp / "secret-redactor" / "redact_secrets.py"
    proc = run_review_tail(
        harness,
        tmp_path,
        "Flagged 1 issue inline — see comments.",
        [denied_inline(f"commits `{key}`")],
        before_guard=redactor_file.unlink,
    )
    assert proc.returncode != 0
    # The summary posted before the redactor went; the guard posts nothing.
    assert len(harness.posts()) == 1 and not [b for b in harness.bodies() if "lost-findings" in b]
    assert "could not redact the findings recovered from the transcript" in harness.logs[-1]
    assert_gone(harness.everything(), [key])


def codex_stub(verdict):
    return (
        "#!/usr/bin/env bash\n"
        'if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0-fixture"; exit 0; fi\n'
        'echo "model: $CODEX_MODEL"\n'
        "echo 'reasoning effort: low'\n"
        "echo 'codex'\n"
        f"cat <<'VERDICT'\n{verdict}\nVERDICT\n"
    )


def run_codex(tmp_path, verdict, with_redactor=True):
    harness = Harness(tmp_path, with_redactor=with_redactor)
    write_executable(harness.bin / "codex", codex_stub(verdict))
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    job_env = load(CODEX[0])["jobs"][CODEX[1]]["env"]
    values = {
        **VALUES,
        "github.event.pull_request.base.ref": "main",
        "github.event.pull_request.title": "Rotate the fallback key",
        "github.event.pull_request.base.sha": "0" * 40,
    }
    env = {"CODEX_MODEL": job_env["CODEX_MODEL"], "CODEX_SCRIPTS": str(SCRIPTS)}
    # The shipped steps write /tmp/...; each test gets its own.
    review = shipped(find(CODEX, name="Run Codex adversarial review")).replace("/tmp/", f"{fixtures}/")
    post = shipped(find(CODEX, name="Post review comment")).replace("/tmp/", f"{fixtures}/")
    first = harness.run(find(CODEX, name="Run Codex adversarial review"), values, env, script=review)
    second = harness.run(find(CODEX, name="Post review comment"), values, env, script=post) if first.returncode == 0 else None
    return harness, fixtures, first, second


def test_the_codex_lane_posts_findings_redacted(tmp_path):
    key, password = "at_" + rand(29), rand(20)
    verdict = f"regression: config.py:12 - the fallback key {key} (DB_PASSWORD={password}) has no test\nVERDICT: REGRESSION"
    harness, fixtures, review, post = run_codex(tmp_path, verdict)
    assert review.returncode == 0 and post.returncode == 0, "\n".join(harness.logs)
    (body,) = harness.bodies()
    assert "regression: config.py:12 - the fallback key [REDACTED whoisxml-api-key]" in body
    assert_gone(harness.everything() + (fixtures / "codex.verdict.full").read_text(), [key, password])


def test_the_codex_lane_logs_and_summarizes_an_all_clear_redacted(tmp_path):
    key = "at_" + rand(29)
    verdict = f"No regressions found. config.py moves {key} to the environment.\nVERDICT: CLEAN"
    harness, fixtures, review, post = run_codex(tmp_path, verdict)
    assert review.returncode == 0 and post.returncode == 0, "\n".join(harness.logs)
    assert harness.posts() == [], "an all-clear is not posted"
    assert "[REDACTED whoisxml-api-key]" in harness.summary.read_text()
    assert_gone(harness.everything(), [key])


def test_the_codex_log_never_shows_a_key_the_pr_removes(tmp_path):
    # Codex prints the diff it reads; a key the PR removes streams as `-`
    # lines. The log and every file cut from the stream stay clean.
    block, lines = pem_block()
    removed = "\n".join("-" + line for line in block.splitlines())
    key = "at_" + rand(29)
    harness = Harness(tmp_path)
    write_executable(
        harness.bin / "codex",
        "#!/usr/bin/env bash\n"
        'if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0-fixture"; exit 0; fi\n'
        'echo "model: $CODEX_MODEL"\n'
        f"cat <<'DIFF'\nexec git diff origin/main...HEAD\n--- a/deploy/key.pem\n+++ /dev/null\n@@ -1,6 +0,0 @@\n{removed}\n-apiKey={key}\nDIFF\n"
        "printf 'codex\\nNo regressions found.\\nVERDICT: CLEAN\\n'\n",
    )
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    values = {
        **VALUES,
        "github.event.pull_request.base.ref": "main",
        "github.event.pull_request.title": "Remove the deploy key",
        "github.event.pull_request.base.sha": "0" * 40,
    }
    env = {"CODEX_MODEL": load(CODEX[0])["jobs"][CODEX[1]]["env"]["CODEX_MODEL"], "CODEX_SCRIPTS": str(SCRIPTS)}
    review = shipped(find(CODEX, name="Run Codex adversarial review")).replace("/tmp/", f"{fixtures}/")
    proc = harness.run(find(CODEX, name="Run Codex adversarial review"), values, env, script=review)
    assert proc.returncode == 0, harness.logs[-1]
    stream = (fixtures / "codex.out").read_text()
    assert "[REDACTED private-key]" in stream and "-apiKey=[REDACTED whoisxml-api-key]" in stream
    assert_gone(harness.everything() + stream, lines + [key])


def test_the_codex_lane_without_the_redactor_posts_nothing_and_fails(tmp_path):
    key = "at_" + rand(29)
    harness, fixtures, review, post = run_codex(tmp_path, f"regression: config.py:12 - {key}\nVERDICT: REGRESSION", with_redactor=False)
    assert review.returncode != 0 and post is None
    assert harness.posts() == []


# ---------------------------------------------------------------------------
# 5. Check what the review posted for credentials

CHECK = "Check what the review posted for credentials"


def comment(login, created_at, body, url="https://github.com/o/r/pull/478#discussion_r1"):
    return {"user": {"login": login}, "created_at": created_at, "html_url": url, "body": body}


def run_check(tmp_path, inline=(), issue=(), extra_env=None, script=None, started_at="2026-10-22T20:00:00Z", before=None):
    harness = Harness(tmp_path)
    if before is not None:
        before(harness)
    pulls, issues = tmp_path / "pulls.json", tmp_path / "issues.json"
    # Two pages each, back to back, as `gh api --paginate` prints them.
    pulls.write_text(json.dumps(list(inline[:1])) + json.dumps(list(inline[1:])))
    issues.write_text(json.dumps(list(issue[:1])) + json.dumps(list(issue[1:])))
    values = {**VALUES, "steps.clock.outputs.started_at": started_at}
    proc = harness.run(
        find(REVIEW, name=CHECK), values, {"GH_PULLS_JSON": str(pulls), "GH_ISSUES_JSON": str(issues), **(extra_env or {})}, script=script
    )
    return proc, harness.logs[-1]


def test_the_check_is_the_last_step_and_runs_after_any_posting_step():
    names = [s.get("name") for s in steps(REVIEW)]
    assert names[-1] == CHECK
    condition = find(REVIEW, name=CHECK)["if"]
    for want in ("!cancelled()", "steps.bot_check.outputs.skipped != 'true'", "steps.claude.outcome != 'skipped'"):
        assert want in condition
    assert find(REVIEW, name=CHECK)["env"]["STARTED_AT"] == "${{ steps.clock.outputs.started_at }}"


@pytest.mark.parametrize("login", ["claude[bot]", "github-actions[bot]"])
@pytest.mark.parametrize("listing", ["inline", "issue"])
def test_the_check_fails_on_a_value_that_landed(tmp_path, login, listing):
    key = "at_" + rand(29)
    leaked = comment(login, "2026-10-22T20:03:00Z", f"commits `{key}`", url="https://github.com/o/r/pull/478#leak")
    clean = comment(login, "2026-10-22T20:04:00Z", "No issues found.")
    batch = {"inline": (clean, leaked), "issue": ()}
    if listing == "issue":
        batch = {"inline": (clean,), "issue": (clean, leaked)}
    proc, log = run_check(tmp_path, batch["inline"], batch["issue"])
    assert proc.returncode == 1, log
    assert "::error::" in log and "https://github.com/o/r/pull/478#leak" in log and "whoisxml-api-key" in log
    assert_gone(log, [key])


@pytest.mark.parametrize(
    "case",
    ["before-the-review", "another-author", "redacted", "nothing-posted"],
)
def test_the_check_passes_what_this_review_did_not_leak(tmp_path, case):
    key = "at_" + rand(29)
    inline = {
        "before-the-review": (comment("claude[bot]", "2026-10-22T19:59:59Z", f"`{key}`"),),
        "another-author": (comment("someone", "2026-10-22T20:05:00Z", f"`{key}`"),),
        "redacted": (comment("claude[bot]", "2026-10-22T20:05:00Z", "commits `[REDACTED whoisxml-api-key]`"),),
        "nothing-posted": (),
    }[case]
    proc, log = run_check(tmp_path, inline)
    assert proc.returncode == 0, log
    assert "::error::" not in log
    assert_gone(log, [key])


def test_the_check_fails_when_the_redactor_fails(tmp_path):
    harness_root = tmp_path / "h"
    proc, log = run_check(
        harness_root,
        (comment("claude[bot]", "2026-10-22T20:05:00Z", "No issues found."),),
        before=lambda harness: write_executable(
            harness.runner_temp / "secret-redactor" / "redact_secrets.py", "import sys\nsys.exit(3)\n"
        ),
    )
    assert proc.returncode == 1 and "::error::" in log and "unchecked" in log, log


def test_the_check_warns_when_it_cannot_read_or_has_no_start_time(tmp_path):
    proc, log = run_check(tmp_path / "a", (), extra_env={"GH_LIST_FAIL": "1"})
    assert proc.returncode == 0 and "::warning::" in log
    proc, log = run_check(tmp_path / "b", (comment("claude[bot]", "2026-10-22T20:05:00Z", "at_" + rand(29)),), started_at="")
    assert proc.returncode == 0 and "::warning::" in log


# ---------------------------------------------------------------------------
# 6. Negative controls: each mutation must be caught by a check above.


def test_a_dropped_pattern_is_caught(redactor, tmp_path):
    source = redactor_source().replace('("whoisxml-api-key", r"at_[A-Za-z0-9]{29}(?![A-Za-z0-9])"),\n', "")
    assert source != redactor_source(), "mutation did not apply"
    path = tmp_path / "mutant.py"
    path.write_text(source)
    spec = importlib.util.spec_from_file_location("redact_mutant", path)
    mutant = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mutant)
    kind, value = VENDOR[0]
    assert kind == "whoisxml-api-key"
    with pytest.raises(AssertionError):
        test_a_vendor_shaped_value_never_survives(mutant, kind, value, "prose")


@pytest.mark.parametrize(
    "lane, step_id, call",
    [
        (REVIEW, "summary", 'python3 "${RUNNER_TEMP}/secret-redactor/redact_secrets.py" "$summary"'),
        (ADVERSARIAL, "verdict", 'python3 "${RUNNER_TEMP}/secret-redactor/redact_secrets.py" "$verdict"'),
    ],
    ids=["review-summary", "adversarial-verdict"],
)
def test_a_posting_step_without_its_redaction_is_caught(tmp_path, lane, step_id, call):
    script = shipped(find(lane, step_id=step_id))
    assert call in script, "the redaction call moved; update the mutation"
    mutant = script.replace(call, "true", 1)
    harness = Harness(tmp_path)
    message, planted = planted_message()
    values = {**VALUES, "steps.claude.outputs.execution_file": str(transcript(tmp_path, message)), "steps.claude.outcome": "success"}
    harness.run(find(lane, step_id=step_id), values, script=mutant)
    with pytest.raises(AssertionError):
        assert_gone(harness.everything(), planted)


def test_a_guard_without_its_redaction_is_caught(tmp_path):
    script = shipped(find(REVIEW, step_id="guard"))
    calls = [
        'python3 "$REDACTOR" --json "$T/denials.json"',
        'python3 "$REDACTOR" "$T/denied.md" "$T/errored.md" "$T/unlanded.md" "$T/subagents.full.md" "$T/final.full.md"',
    ]
    for call in calls:
        assert call in script, "the redaction call moved; update the mutation"
    for index, call in enumerate(calls):
        harness = Harness(tmp_path / str(index))
        key = "at_" + rand(29)
        run_review_tail(
            harness,
            tmp_path / str(index),
            "Flagged 1 issue inline — see comments.",
            [denied_inline(f"commits `{key}`")],
            guard_script=script.replace(call, "true", 1),
        )
        with pytest.raises(AssertionError):
            assert_gone(harness.everything(), [key])


def test_a_codex_review_step_without_its_redaction_is_caught(tmp_path):
    script = shipped(find(CODEX, name="Run Codex adversarial review"))
    stage = re.compile(r'\n\s*\| python3 "\$\{RUNNER_TEMP:\?RUNNER_TEMP is not set\}/secret-redactor/redact_secrets\.py" \\')
    mutant = stage.sub("", script, count=1)
    assert mutant != script, "the redactor's pipe stage moved; update the mutation"
    key = "at_" + rand(29)
    harness = Harness(tmp_path)
    write_executable(harness.bin / "codex", codex_stub(f"regression: config.py:12 - {key}\nVERDICT: REGRESSION"))
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    values = {
        **VALUES,
        "github.event.pull_request.base.ref": "main",
        "github.event.pull_request.title": "t",
        "github.event.pull_request.base.sha": "0" * 40,
    }
    env = {"CODEX_MODEL": load(CODEX[0])["jobs"][CODEX[1]]["env"]["CODEX_MODEL"], "CODEX_SCRIPTS": str(SCRIPTS)}
    review = mutant.replace("/tmp/", f"{fixtures}/")
    post = shipped(find(CODEX, name="Post review comment")).replace("/tmp/", f"{fixtures}/")
    harness.run(find(CODEX, name="Run Codex adversarial review"), values, env, script=review)
    harness.run(find(CODEX, name="Post review comment"), values, env, script=post)
    with pytest.raises(AssertionError):
        assert_gone(harness.everything(), [key])


@pytest.mark.parametrize("mutation", ["settings-dropped", "settings-input-instead"])
def test_hook_wiring_mutations_are_caught(mutation):
    with_ = dict(review_model_step()["with"])
    if mutation == "settings-dropped":
        with_["claude_args"] = with_["claude_args"].replace(SETTINGS_ARG, "")
    else:
        with_["claude_args"] = with_["claude_args"].replace(SETTINGS_ARG, "")
        with_["settings"] = "${{ runner.temp }}/secret-redactor/settings.json"
    with pytest.raises(AssertionError):
        check_hook_wiring(with_)


@pytest.mark.parametrize(
    "old, new",
    [
        ("  disableAllHooks: false,\n", ""),
        (' --hook || exit 2"', ' --hook"'),
        ('matcher: "mcp__github_inline_comment__create_inline_comment"', 'matcher: "mcp__github_comment__update_claude_comment"'),
    ],
    ids=["disable-dropped", "exit-2-dropped", "matcher-renamed"],
)
def test_settings_file_mutations_are_caught(tmp_path, old, new):
    script = install_script().replace(old, new, 1)
    assert script != install_script(), "mutation did not apply"
    directory = install(tmp_path / "runner_temp", script=script)
    with pytest.raises(AssertionError):
        check_settings_file(json.loads((directory / "settings.json").read_text()), directory)


def test_a_check_without_its_time_filter_is_caught(tmp_path):
    script = shipped(find(REVIEW, name=CHECK))
    mutant = re.sub(r'\n\s*and \(\(\.created_at // ""\) >= \$since\)', "", script, count=1)
    assert mutant != script, "the time filter moved; update the mutation"
    key = "at_" + rand(29)
    proc, log = run_check(tmp_path, (comment("claude[bot]", "2026-10-22T19:00:00Z", f"`{key}`"),), script=mutant)
    assert proc.returncode == 1, "without the filter, a comment from before the review would fail it"
    assert_gone(log, [key])


# Inputs that made a pattern rescan or backtrack quadratically before it was
# fixed, each at 256 KiB: linear, each runs in milliseconds; quadratic, minutes.
SLOW_SHAPES = {
    "blank run after a key header": lambda n: "-----BEGIN PRIVATE KEY-----\n" + " " * n + "!\n",
    "letters and dashes": lambda n: "a-" * (n // 2),
    "letters and dots": lambda n: "a." * (n // 2),
    "eyJ run": lambda n: "eyJ" * (n // 3),
    "base64url blob": lambda n: "".join(random.Random(5).choice(B64URL.replace("_", "")) for _ in range(n)),
    "key headers without an end": lambda n: "-----BEGIN RSA PRIVATE KEY-----\n" * (n // 32),
    "slack prefixes": lambda n: "xoxb-" * (n // 5),
    "openai prefixes": lambda n: "sk-" * (n // 3),
    "quoted labels": lambda n: '"password": "' * (n // 13),
    "url credentials": lambda n: "https://" + "a:" * (n // 2),
    "many key headers on one line": lambda n: "-----BEGIN PRIVATE KEY-----" * (n // 27),
}


@pytest.mark.parametrize("shape", sorted(SLOW_SHAPES))
def test_no_pattern_backtracks_quadratically(redactor, shape):
    # The hook times out open, so a slow pattern is a leak path, not only a
    # stall. Generous budget: a linear pass takes milliseconds here.
    import time

    text = SLOW_SHAPES[shape](256 * 1024)
    start = time.perf_counter()
    redactor.redact(text)
    assert time.perf_counter() - start < 3, f"{shape}: redaction is not linear"


def test_shlex_reads_the_settings_path_as_one_argument():
    # claude-code-action splits claude_args with shell-quote: the quoted path
    # must stay one argument after the runner fills in runner.temp.
    args = review_model_step()["with"]["claude_args"].replace("${{ runner.temp }}", "/home/runner/work/_temp")
    tokens = shlex.split(args)
    index = tokens.index("--settings")
    assert tokens[index + 1] == "/home/runner/work/_temp/secret-redactor/settings.json"
