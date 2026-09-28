# NEGATIVE: a wildcard role name would let ci pass ANY role (privilege escalation).
# Expected: "ci_ecs_task_role_name must be a valid IAM role name"
ci_ecs_task_role_name = "*"
