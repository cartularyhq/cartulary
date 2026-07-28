// SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

export type ReadinessGap = {
  key: string;
  level: "required" | "preferred";
  status: "missing" | "stale" | "missing_card";
  source_policy: "from-memory" | "ask-peer" | "either";
  elicitation: {
    allowed: boolean;
    prompt?: string;
    submit_via?: "ingest";
    then?: "check_readiness";
  };
};

export type ReadinessReport = {
  report_version: "f9-1";
  ready: boolean;
  blocked: boolean;
  blockers: ReadinessGap[];
  warnings: ReadinessGap[];
};

export type ElicitationPlan = {
  canProceed: boolean;
  prompts: Array<{ requirementKey: string; prompt: string; blocking: boolean }>;
  hardBlockers: ReadinessGap[];
  warnings: ReadinessGap[];
};

export class SkillReadinessBlockedError extends Error {
  readonly report: ReadinessReport;
  readonly plan: ElicitationPlan;

  constructor(report: ReadinessReport, plan: ElicitationPlan) {
    super("Skill readiness has required gaps.");
    this.name = "SkillReadinessBlockedError";
    this.report = report;
    this.plan = plan;
  }
}

export function buildElicitationPlan(report: ReadinessReport): ElicitationPlan {
  const gaps = [...report.blockers, ...report.warnings];
  const prompts = gaps
    .filter((gap) => gap.elicitation.allowed && gap.elicitation.prompt)
    .map((gap) => ({
      requirementKey: gap.key,
      prompt: gap.elicitation.prompt as string,
      blocking: gap.level === "required",
    }));

  return {
    canProceed: !report.blocked,
    prompts,
    hardBlockers: report.blockers.filter((gap) => !gap.elicitation.allowed),
    warnings: report.warnings,
  };
}

export function requireSkillReady(report: ReadinessReport): ElicitationPlan {
  const plan = buildElicitationPlan(report);

  if (!plan.canProceed) {
    throw new SkillReadinessBlockedError(report, plan);
  }

  return plan;
}
