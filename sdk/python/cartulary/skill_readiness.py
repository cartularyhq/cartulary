# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

"""Provider-neutral helpers for Cartulary's ``f9-1`` readiness report."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class ElicitationPrompt:
    requirement_key: str
    prompt: str
    blocking: bool


@dataclass(frozen=True)
class ElicitationPlan:
    can_proceed: bool
    prompts: tuple[ElicitationPrompt, ...]
    hard_blockers: tuple[dict[str, Any], ...]
    warnings: tuple[dict[str, Any], ...]


class SkillReadinessBlockedError(RuntimeError):
    """Raised when a helper path attempts to run with required gaps."""

    def __init__(self, report: dict[str, Any], plan: ElicitationPlan) -> None:
        super().__init__("Skill readiness has required gaps.")
        self.report = report
        self.plan = plan


def build_elicitation_plan(report: dict[str, Any]) -> ElicitationPlan:
    """Convert a readiness report into prompts without performing model calls."""

    blockers = tuple(report.get("blockers", ()))
    warnings = tuple(report.get("warnings", ()))
    gaps = blockers + warnings

    prompts = tuple(
        ElicitationPrompt(
            requirement_key=gap["key"],
            prompt=gap["elicitation"]["prompt"],
            blocking=gap["level"] == "required",
        )
        for gap in gaps
        if gap.get("elicitation", {}).get("allowed")
        and gap.get("elicitation", {}).get("prompt")
    )

    return ElicitationPlan(
        can_proceed=not bool(report.get("blocked")),
        prompts=prompts,
        hard_blockers=tuple(
            gap for gap in blockers if not gap.get("elicitation", {}).get("allowed")
        ),
        warnings=warnings,
    )


def require_skill_ready(report: dict[str, Any]) -> ElicitationPlan:
    """Block the caller's skill path until all required gaps are resolved."""

    plan = build_elicitation_plan(report)
    if not plan.can_proceed:
        raise SkillReadinessBlockedError(report, plan)
    return plan
