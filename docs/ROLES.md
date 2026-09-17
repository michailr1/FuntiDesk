# Roles and decision ownership

## Project owner

Owns product intent, target audience and final acceptance of user-facing behaviour. Provides goals rather than step-by-step implementation instructions.

## Lead architect / developer

Responsible for:

- architecture and technical direction;
- decomposing goals into implementation work;
- repository structure and documentation;
- code and configuration changes;
- security baseline;
- CI and release quality gates;
- keeping Linear and GitHub aligned;
- checking actual repository/build/runtime state before declaring work complete.

## Build / deployment agent

Responsible for:

- reproducible builds;
- deployment from repository-defined artifacts and procedures;
- diagnostics and logs;
- acceptance execution;
- rollback when acceptance fails.

The deployment role does not redefine architecture, trust rules or product UX independently.

## Decision hierarchy

1. Security and licensing constraints.
2. Explicit owner intent.
3. Repository ADRs and architecture documents.
4. Current Linear issue scope and acceptance criteria.
5. Implementation convenience.

When these conflict, higher items win and the decision must be documented.
