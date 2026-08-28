"""Static checks over the shell scripts and the Makefile.

Bash gives you no type checker, and these scripts are the manual steps — the
parts that only ever run against real AWS, where a mistake costs a round trip.
These assertions are cheap and catch the failure modes that have actually
happened here.
"""

import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = sorted(ROOT.glob("scripts/*.sh"))
MAKEFILE = ROOT / "Makefile"


def uses_errexit(source):
    return bool(re.search(r"^set -[a-z]*e[a-z]*", source, re.M))


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
class TestEveryScript:
    def test_parses(self, script):
        result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr

    def test_is_executable(self, script):
        assert script.stat().st_mode & 0o111, f"chmod +x {script.relative_to(ROOT)}"

    def test_has_a_shebang(self, script):
        assert script.read_text().startswith("#!"), "needs #!/usr/bin/env bash"

    def test_empty_results_do_not_abort_the_script(self, script):
        """Regression: `make etl` failed on a *successful* run.

        `aws s3 ls` exits 1 when a prefix does not exist, and `grep` exits 1 when
        it matches nothing. Both are normal outcomes — no quarantined rows, no
        partitions yet. Inside `VAR=$(...)` under `set -e`, either one kills the
        script, and in two places that made the error message explaining what to
        do next unreachable.

        Any assignment whose command substitution can legitimately come back
        empty must carry a `||` fallback.
        """
        source = script.read_text()
        if not uses_errexit(source):
            return

        # Join continuations so a wrapped assignment is judged as one statement.
        joined = re.sub(r"\\\n\s*", " ", source)

        offenders = []
        for line in joined.splitlines():
            stripped = line.strip()
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=\$\(", stripped):
                continue
            # Commands whose failure means "nothing there", not "broken".
            if not re.search(r"aws s3 ls|\|\s*grep", stripped):
                continue
            if "||" not in stripped:
                offenders.append(stripped[:120])

        assert not offenders, (
            "unguarded command substitution where empty is a normal result:\n  "
            + "\n  ".join(offenders)
        )


@pytest.mark.parametrize(
    "script", ["smoke_test_endpoint.sh", "verify.sh"], ids=lambda n: n
)
class TestVerdicts:
    """Both scripts answer "did it work?", so the answer must be unmissable in a
    wall of JSON, and must exit non-zero when it is no."""

    @pytest.fixture
    def source(self, script):
        return (ROOT / "scripts" / script).read_text()

    def test_states_a_verdict_both_ways(self, source):
        assert re.search(r"PASSED|HEALTHY", source), "no success verdict"
        assert re.search(r"FAILED|PROBLEMS FOUND", source), "no failure verdict"

    def test_counts_what_it_checked(self, source):
        assert re.search(r"%d (of %d )?check", source), "verdict states no count"

    def test_exits_non_zero_on_failure(self, source):
        assert "exit 1" in source


class TestSmokeTestAssertions:
    @pytest.fixture
    def source(self):
        return (ROOT / "scripts" / "smoke_test_endpoint.sh").read_text()

    def test_the_api_key_is_checked_before_any_request(self, source):
        """An unreadable key was sent as an empty header, and every check
        returned 403 — nine failures describing one problem, none naming it."""
        assert 'API_KEY" == "None"' in source or '"$API_KEY" == "None"' in source
        assert source.index("could not read the value of API key") < source.index("check \"scores one order\"")

    def test_comparison_checks_require_a_successful_response(self, source):
        """The mixed-case check asserted only that two responses were equal.
        Two identical 403s are equal, so it reported ok while every request was
        being refused."""
        assert "refund_probability*" in source, (
            "the mixed-case check must require a prediction, not just agreement"
        )


class TestMakefile:
    @pytest.fixture(scope="class")
    def makefile(self):
        return MAKEFILE.read_text()

    def test_every_script_it_calls_exists(self, makefile):
        missing = [
            path for path in re.findall(r"(scripts/[a-z_]+\.sh)", makefile)
            if not (ROOT / path).exists()
        ]
        assert not missing, missing

    def test_apply_is_never_auto_approved(self, makefile):
        # D-07: a developer reviews the plan. An auto-approving target would
        # silently delete that decision.
        #
        # Comments are stripped first — the header explains that the flag is
        # deliberately absent, and matching that text would be a false positive.
        recipes = [
            line for line in makefile.splitlines()
            if not line.lstrip().startswith("#")
        ]
        assert not [line for line in recipes if "-auto-approve" in line]

    def test_every_target_is_documented(self, makefile):
        # `make help` is generated from these comments, so an undocumented
        # target is an invisible one.
        targets = set(re.findall(r"^([a-z][a-z-]*):", makefile, re.M))
        documented = set(re.findall(r"^([a-z][a-z-]*):.*?##", makefile, re.M))
        assert not targets - documented

    def test_promote_can_find_the_line_it_edits(self):
        """`promote_model.sh` rewrites `approved_model_package_arn` with sed.
        If the assignment is reformatted past what its pattern matches, the
        script refuses rather than corrupting the file — but the refusal is a
        failed promotion, so the shape is worth pinning."""
        tfvars = (ROOT / "envs" / "dev" / "terraform.tfvars").read_text()
        matches = re.findall(
            r'^[ \t]*approved_model_package_arn[ \t]*=[ \t]*"[^"]*"[ \t]*$',
            tfvars,
            re.M,
        )
        assert len(matches) == 1, "expected exactly one assignment the script can rewrite"

    def test_targets_are_phony(self, makefile):
        """None of these produce a file of their own name, so a stray file
        called `test` or `check` would otherwise silently disable the target."""
        phony = set(re.findall(r"[a-z-]+", re.search(
            r"\.PHONY:(.*?)\n\n", makefile, re.S).group(1)))
        targets = set(re.findall(r"^([a-z][a-z-]*):.*?##", makefile, re.M))
        assert not targets - phony
