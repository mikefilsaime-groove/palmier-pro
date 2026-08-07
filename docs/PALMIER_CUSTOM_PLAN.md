# Palmier Pro Custom: Fal.ai BYOK Plan

## Purpose and scope

This fork will add bring-your-own-key (BYOK) Fal.ai generation for image, video, and audio while retaining Palmier Pro's editor, generation UI, media preprocessing, placeholders, project persistence, result downloads, timeline integration, and MCP surface.

The integration should be a contained provider addition rather than a broad rewrite. The goal is to minimize conflicts with Palmier's rapidly changing upstream code and make upstream updates routine.

This document records the initial investigation and architecture direction. No Fal.ai implementation was included in the repository-setup change.

## Repository baseline

- Official upstream: `palmier-io/palmier-pro`
- Custom fork: `mikefilsaime-groove/palmier-pro`
- Baseline upstream commit: `5ddc2fa5dcab76f5f2cbe56f26c83c62302bff41`
- `main` is reserved as a clean, fast-forward mirror of `upstream/main`.
- `fal-integration` is the long-lived customization branch.
- Palmier's Git history is preserved in full; this repository was cloned from the GitHub fork rather than initialized or populated manually.

## Findings carried forward from the original investigation

### Product and platform

- Palmier Pro is a native Swift 6.2 macOS application built with SwiftUI, AppKit, and AVFoundation. It is not an Electron app.
- Current upstream supports macOS 26 Tahoe on Apple Silicon.
- The app exposes its MCP server at `http://127.0.0.1:19789/mcp` when Palmier Pro is running and MCP is enabled.
- The previous task registered that endpoint globally in Codex and locally for Claude in the previous task's project. Claude configuration may need to be added again for this checkout when end-to-end MCP testing begins.

### Open-source versus closed-generation boundary

- Palmier Pro's repository is licensed under GPLv3, so the released source can be used and modified in a private or redistributed fork subject to the license.
- Palmier's README explicitly describes the editor, MCP server, and agent chat as open source, while describing generative-AI processing as closed source and requiring login and subscription.
- The released desktop code contains the generation UI and orchestration, but the official model catalog and execution path depend on Palmier's hosted backend:
  - `ModelCatalog` subscribes to the Convex query `models:list`.
  - `GenerationBackend` uploads references through Palmier storage, submits `generations:submit`, and subscribes to `generations:byId` for job state.
  - `GenerationService` creates placeholders, preprocesses references, records job metadata, monitors jobs, downloads results, installs media into the project, and resumes pending jobs.
  - Agent/MCP generation in `ToolExecutor+Generate` currently requires Palmier sign-in, credits, and—where applicable—a paid plan.
- Palmier already supports Anthropic and OpenAI BYOK for agent chat, including macOS Keychain storage, but it does not provide BYOK for image, video, or audio generation.
- GitHub issue [#53, BYOK for generative features](https://github.com/palmier-io/palmier-pro/issues/53), requested this capability. A Palmier contributor said they were unlikely to support it at that time because the models span multiple providers and APIs, and the issue was closed.

The practical boundary is therefore not a prohibition on modifying the GPL application. It is the absence of Palmier's proprietary processing backend and an official local provider adapter. This fork will supply an independent Fal.ai path without attempting to reproduce Palmier's private backend.

## Architecture direction

### Provider boundary

Introduce a small generation-provider abstraction between `GenerationService` and the current static `GenerationBackend`. It should own the provider-specific operations required by an asynchronous generation job:

1. Resolve a catalog model to its provider and endpoint.
2. Upload local reference media when the endpoint requires hosted URLs.
3. Map Palmier's normalized generation input to the selected Fal endpoint's schema.
4. Submit the Fal queue request.
5. Monitor or poll queue status with cancellation and bounded retries.
6. Normalize terminal success, failure, and output URLs for the existing finalization path.
7. Resume pending provider jobs after a project is reopened.

Palmier's existing Convex implementation should remain available as one provider path where practical. Fal-specific HTTP, queue, upload, and response logic should live in a dedicated directory such as `Sources/PalmierPro/Generation/Providers/Fal/`, not be distributed throughout SwiftUI views or agent tools.

### Credentials

- Store the Fal API key in the macOS Keychain through the existing `KeychainStore` infrastructure.
- Never persist the key in project files, `UserDefaults`, logs, analytics, MCP results, or Git.
- Add a generation-provider settings surface distinct from chat-agent credentials, with add, replace, validate, and remove behavior.
- Support a development-only `FAL_KEY` environment override only if it follows Palmier's established debug credential pattern and never changes release behavior.

### Model catalog

The official catalog is remotely supplied by `models:list`, so Fal models need a source that does not depend on Palmier's backend. The first version should use a small, explicitly maintained Fal catalog whose entries map into Palmier's existing `CatalogEntry` and model-config types where those types accurately describe the endpoint.

Catalog entries need an explicit provider identity and Fal endpoint identifier. Provider selection must not be inferred from display names. Endpoint-specific parameter mapping should stay with the Fal adapter, while shared UI capabilities—durations, aspect ratios, references, source requirements, and output kind—should continue to drive Palmier's existing forms and validation.

Do not attempt to expose every Fal model in the first change. Start with one well-understood text-to-image endpoint and grow the catalog only after the provider path works end to end.

### Persistence and recovery

`GenerationInput` in `Sources/PalmierPro/Models/MediaManifest.swift` currently persists `backendJobId` but not a provider identity. A multi-provider implementation must persist enough provider and endpoint metadata to route job recovery correctly after reopening a project.

The persisted form should remain free of credentials. It should support queued, running, succeeded, failed, cancelled, and stale/unavailable jobs without silently switching providers or resubmitting work that could incur duplicate cost.

### Login, plan, and cost behavior

- Palmier-backed models should retain their existing account, credit, and paid-plan rules.
- Fal-backed models should require a configured Fal key, not a Palmier login or Palmier credits.
- The UI and MCP responses must identify the active provider and report that Fal usage is billed directly to the user's Fal account.
- Palmier credit estimates cannot be reused as Fal prices. The first implementation may omit an estimate or label it unavailable; any later estimate must come from an explicit Fal pricing source and must not be treated as an exact bill.

### Shared UI and MCP behavior

The same domain submission operation should serve both the generation UI and Agent/MCP tools. Provider selection, eligibility, validation, parameter mapping, persistence, and terminal errors must not be implemented separately in each surface.

MCP `list_models` should expose stable provider and endpoint metadata. `generate_image`, `generate_video`, and `generate_audio` should route Fal models without the current unconditional Palmier sign-in and credit checks, while retaining those checks for Palmier models. Results should continue to return placeholder asset IDs and remain observable through existing media inspection tools.

## Likely code areas to modify

| Area | Current files or directories | Expected work |
| --- | --- | --- |
| Credentials | `Sources/PalmierPro/Utilities/KeychainStore.swift`, `Sources/PalmierPro/Settings/` | Add Fal credential ownership and settings UI without exposing secrets. |
| Catalog | `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift`, model config files, `ModelPreferences.swift` | Merge Palmier and Fal catalog entries, attach provider identity, and preserve stable model IDs. |
| Provider runtime | `Sources/PalmierPro/Generation/GenerationBackend.swift`, new `Generation/Providers/` files | Extract a provider contract and implement Fal uploads, queue submission, status, cancellation, errors, and result normalization. |
| Orchestration | `Sources/PalmierPro/Generation/GenerationService.swift` | Route by provider while reusing placeholders, preprocessing, downloads, project installation, notifications, and recovery. |
| Input mapping | `Sources/PalmierPro/Generation/Submission/`, catalog parameter structs | Translate normalized image, video, and audio requests to endpoint-specific Fal schemas. |
| Persistence | `Sources/PalmierPro/Models/MediaManifest.swift`, generation recovery in `GenerationService` | Persist provider-safe job identity and resume the correct provider without persisting credentials. |
| Generation UI | `Sources/PalmierPro/Generation/UI/`, `Sources/PalmierPro/Settings/ModelsPane.swift` | Show provider/key state, remove Palmier-only gating for Fal models, and present provider-appropriate cost language. |
| Agent and MCP | `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift`, `ToolDefinitions.swift`, `AgentInstructions.swift` | Make catalog discovery and generation routing provider-aware while preserving shared domain behavior. |
| Activity and analytics | `Sources/PalmierPro/Editor/ProjectActivityView.swift`, generation analytics | Avoid treating Fal work as Palmier credit activity and avoid leaking prompts, keys, or sensitive URLs. |
| Tests | `Tests/PalmierProTests/Generation/`, `Tests/PalmierProTests/Agent/` | Add deterministic provider routing, mapping, error, cancellation, recovery, catalog, and MCP boundary coverage with mocked networking. |

## Proposed implementation sequence

1. Trace and characterize the current generation lifecycle with focused tests around the provider seam and persisted recovery data.
2. Define the provider contract, provider-aware model identity, normalized job state, and secret-free persisted metadata.
3. Add Keychain-backed Fal credentials and a minimal local catalog containing one text-to-image model.
4. Complete one image-generation vertical slice through UI and MCP: validate, upload if needed, submit, monitor, download, persist, recover, and report errors.
5. Add video generation, including source/reference preprocessing, long-running queue behavior, cancellation, and recovery.
6. Add audio generation and endpoint-specific output handling.
7. Expand the Fal catalog only after each model's capabilities, inputs, output shape, and validation are covered.
8. Run Swift unit tests, build the app, exercise the MCP boundary in an isolated test project, and complete manual UI verification on macOS.

## Upstream synchronization strategy

Never commit custom work directly to `main`, and never merge `fal-integration` back into `main`. Update in this order:

```bash
git switch main
git fetch upstream --prune
git merge --ff-only upstream/main
git push origin main

git switch fal-integration
git merge main
# Resolve conflicts, then build and test.
git push origin fal-integration
```

Use ordinary merge commits when bringing the published `main` history into `fal-integration`; this avoids routine force pushes. Rebase is acceptable only before shared custom commits exist or when explicitly chosen for a bounded cleanup.

To reduce recurring conflicts:

- Keep Fal code in provider-specific files.
- Change Palmier-owned types only where a stable provider seam or persisted provider identity is required.
- Reuse existing submission and finalization operations instead of duplicating them.
- Sync frequently, preferably after meaningful upstream releases rather than allowing a large divergence.
- Run the relevant focused tests after conflict resolution, followed by `swift build` and the broader affected suite.

## Next implementation step

The next task should be an architecture-and-test pass focused on `GenerationService`, `GenerationBackend`, `ModelCatalog`, `GenerationInput`, and `ToolExecutor+Generate`. Its deliverable should be a small provider contract plus tests that prove Palmier-backed behavior remains unchanged. After that seam is established, implement one Fal text-to-image endpoint as the first complete vertical slice.
