# CreatorStudio Editor Architecture and Upstream Plan

## Product boundary

CreatorStudio Editor is a native Swift macOS application derived from Palmier Pro's full GPLv3 history. It keeps Palmier's local editor, timeline, project package, export, Agent, and MCP capabilities while replacing Palmier's account, credits, model catalog, hosted generation, telemetry, feedback, and release services.

The public product name is **CreatorStudio Editor**. The bundle identifier is `gg.creatorstudio.editor`, and the executable Swift module and `.palmier` project format remain unchanged to preserve project compatibility and reduce upstream merge conflicts.

Palmier's repository supplies the open-source editor and desktop orchestration. Palmier's production catalog, credits, hosted generation, cloud transcription, hosted Agent fallback, telemetry, feedback, and update credentials are not part of the reusable open-source service boundary. CreatorStudio Editor supplies independent service implementations and never calls Palmier's private generation or billing systems.

## Access policy

- The complete desktop editor is available to anyone who downloads it.
- No account or entitlement gates project creation, editing, saving, duplication, export, the in-app Agent, generation UI, or mutating MCP tools.
- Provider-specific work still requires that provider's credential or connection: Codex for GPT Image 2, ElevenLabs for audio, and CreatorStudio account sync for Fal.ai catalogs and jobs.
- Hosted services remain free to reject invalid, revoked, or unauthorized service requests, but those responses never lock the local editor.

## Optional one-time CreatorStudio account sync

CreatorStudio Editor can optionally connect to CreatorStudio for Fal.ai. The desktop creates a ten-minute pairing session and displays a human-readable code. The user explicitly authorizes it with either the ScalePlus ProMax SuperPowers Plugin or ClickCampaigns GodMode MCP, then performs a one-time exchange for a dedicated `creatorstudio-editor` token. The desktop never reads, copies, or embeds the MCP's own credential.

The app-specific token is stored in macOS Keychain and restored after relaunch. CreatorStudio Editor does not perform recurring GodMode entitlement checks, foreground lease refreshes, or seven-day lease validation. It refreshes the Fal.ai connection status when needed, but a transient service failure does not erase the saved token or ask the user to pair again. Disconnecting explicitly clears the local token and attempts server-side revocation.

CreatorStudio signs each CreatorStudio-to-Imager request with a 90-second Ed25519 service JWT. Imager verifies its signature, issuer, audience, role, key ID, and expiry. The private key exists only in CreatorStudio and the public key only in Imager; no shared service secret, MCP token, or administrative Fal key is embedded in the desktop app.

## Generation architecture

`GenerationCoordinator` is the provider-neutral owner used by both UI and MCP submissions. The existing placeholder, project-package installation, persistence, cancellation, timeline placement, notifications, and recovery path remains shared.

Provider precedence is strict:

1. For images, prefer Codex GPT Image 2 when Codex is installed and the preference is enabled. This uses the user's signed-in Codex subscription allowance.
2. A selected Codex job never falls back to Fal.ai after a failure, interruption, or usage limit.
3. Fal.ai catalogs and compilers require the optional one-time CreatorStudio connection.
4. For selected Fal.ai models, when CreatorStudio reports an encrypted user Fal key, submit a durable CreatorStudio job.
5. When CreatorStudio explicitly reports no key, use the user's local Keychain Fal key if present.
6. When neither Fal.ai key exists, show an actionable credential prompt.
7. When CreatorStudio is unavailable or reports an invalid connection, report that failure and do not silently switch credentials.
8. ElevenLabs operations always use the user's local Keychain ElevenLabs credential.

Generation metadata persists provider ID, credential source, model ID, catalog version, endpoint IDs, external job ID, provider request IDs, a credential-free request snapshot, and resumability. Credentials, bearer tokens, ciphertext, and expiring signed URLs are never written into `.palmier` packages.

CreatorStudio and direct Fal queue jobs are durable and resume after relaunch. Interrupted synchronous ElevenLabs requests are marked non-resumable and must be submitted again.

## Model authorities

### Video

CreatorStudio owns the video model catalog, validation, ranking, pricing estimates, and Fal request adapters. The desktop **Help me choose** action creates a short-lived selector session and opens `https://creatorstudio.gg/video-selector?embed=1` in a `WKWebView`.

The selector launch token is hashed at rest and exchanged once for a five-minute, HTTP-only, selector-scoped browser session. The webview never receives the desktop GodMode bearer token. CreatorStudio Editor validates the HTTPS origin, protocol version, selector session ID, model ID, and the model's presence in the current desktop catalog before applying `selection.confirmed`.

### Images

Codex GPT Image 2 is the preferred local image provider when available. CreatorStudio Editor launches the installed Codex app-server, verifies its image-generation capability, and imports the saved result through the same project-safe generation path used by every provider. GPT Image 2 requests are synchronous and non-resumable; interrupted jobs are reported accurately and must be generated again.

Imager remains the Fal.ai image model authority. Its canonical versioned catalog and compiler cover active text-to-image, image editing, and One from Each models. CreatorStudio calls Imager through a service-authenticated internal API. Imager returns validated Fal endpoint/input manifests and never receives or returns a Fal key.

### Audio

The first audio release uses current ElevenLabs APIs for text-to-speech, sound effects, text-to-music, and video-to-music. Voices and compatible TTS models are fetched directly with the user's Keychain credential. Dubbing, voice isolation, and speech-to-speech are deferred.

Local transcription remains available. Palmier-hosted cloud transcription and hosted-credit Agent fallback are removed. Direct user Anthropic and OpenAI keys and external Codex/Claude MCP connections remain supported.

## Hosted API contracts

ClickCampaigns:

- `POST /api/godmode/v1/pairing-sessions`
- `POST /api/godmode/v1/pairing-sessions/{id}/exchange`
- `POST /api/godmode/v1/logout`
- MCP tool `authorize_creatorstudio_editor`

CreatorStudio:

- `GET /api/godmode/v1/connection`
- `GET /api/godmode/v1/models/{video|image}`
- `POST /api/godmode/v1/requests/compile`
- `POST /api/godmode/v1/uploads`
- `POST /api/godmode/v1/uploads/{id}/complete`
- `POST /api/godmode/v1/jobs`
- `GET /api/godmode/v1/jobs/{id}`
- `POST /api/godmode/v1/jobs/{id}/cancel`
- `POST /api/godmode/v1/selector-sessions`

Imager:

- `GET /api/internal/godmode/v1/models/image`
- `POST /api/internal/godmode/v1/requests/compile`

Catalog entries use stable model IDs, media kind, operation, capabilities, settings, catalog version, and estimated provider cost. Jobs use stable IDs, ownership checks, idempotency keys, and terminal states `queued`, `running`, `succeeded`, `failed`, or `cancelled`. Public errors use stable codes, safe messages, and retryability without raw provider responses or secrets.

## Code ownership

| Capability | Primary desktop locations |
| --- | --- |
| Optional one-time CreatorStudio pairing | `Sources/PalmierPro/Account/CreatorStudioSession.swift` |
| Service configuration | `Sources/PalmierPro/Account/CreatorStudioConfiguration.swift` |
| Keychain generation credentials | `Sources/PalmierPro/Generation/GenerationCredentialStore.swift` |
| Provider selection and normalized jobs | `Sources/PalmierPro/Generation/GenerationCoordinator.swift` |
| Codex GPT Image 2 request contract | `Sources/PalmierPro/Generation/CodexImageGeneration.swift` |
| CreatorStudio gateway | `Sources/PalmierPro/Generation/CreatorStudioAPIClient.swift` |
| Direct Fal queue | `Sources/PalmierPro/Generation/FalQueueClient.swift` |
| ElevenLabs | `Sources/PalmierPro/Generation/ElevenLabsClient.swift` |
| Live catalog mapping | `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift` |
| Shared orchestration and recovery | `Sources/PalmierPro/Generation/GenerationService.swift` |
| Selector webview | `Sources/PalmierPro/Generation/UI/VideoModelSelectorView.swift` |
| Secret-free persistence | `Sources/PalmierPro/Models/MediaManifest.swift` |
| UI/MCP generation | `Generation/UI`, `Agent/Tools`, and `Agent/MCP` |

Hosted implementation branches are developed in clean worktrees so unrelated changes in the main ClickCampaigns, CreatorStudio, and Imager checkouts remain untouched.

## Upstream synchronization

`main` is reserved as a clean fast-forward mirror of `upstream/main`. Custom work and releases remain on `fal-integration`.

Palmier ended public source development after the annotated `last-gpl-source` tag at `8805801fa4df8bc2dbc57cb0a854a1f5108f95c6`. Palmier states that releases through 0.7.6 and source through that tag remain GPLv3; later releases are proprietary binaries without corresponding public source. The mirror branch therefore tracks `upstream/main` for history and notices, while CreatorStudio Editor integrates code only through `last-gpl-source`. Proprietary post-tag metadata, license terms, and binaries are never merged into the custom product.

The August 2026 synchronization first established Palmier Pro 0.7.5 (`d2add80e`) as the baseline. The August 30 synchronization then reviewed and integrated the final GPL source on `codex/upstream-last-gpl-source-20260830`; neither update was merged blindly. The final GPL integration adds the transcript-and-marker Timeline Index, marker review status and ripple behavior, audio extraction from video, on-demand Smart Search model installation, docked generation UI, editor chrome improvements, 0–1 inspection grids, static Agent crop controls, composition source reuse, generation-model recommendations, localization expansion, and the Home overlay click fix.

The synchronization deliberately retains CreatorStudio Editor's product boundary: no Palmier account or credit gate, no Palmier generation backend, no Palmier telemetry or feedback service, no Palmier update feed, local-only transcription, and no unsupported upscale action in the desktop Agent or MCP. The CreatorStudio/Fal/ElevenLabs/Codex provider architecture, one-time optional account sync, sample project, project duplication, in-window settings, custom branding, bundle identity, and release infrastructure remain authoritative.

```bash
git switch main
git fetch upstream --prune
git merge --ff-only upstream/main
git push origin main

git switch -c codex/upstream-<date> fal-integration
git merge last-gpl-source
swift build
swift test
```

Use a dedicated review branch and a merge commit when bringing the final published GPL source into `fal-integration`. Do not merge later proprietary upstream commits merely because `main` mirrors them. Keep provider-specific work in dedicated files, keep shared mutations centralized, and never merge custom work back into `main`.

## Releases

`scripts/release.sh` releases only from `fal-integration`, produces `CreatorStudioEditor.dmg`, creates tags such as `creatorstudio-v1.0.0`, publishes explicitly to `mikefilsaime-groove/palmier-pro`, and updates `creatorstudio-appcast.xml`. Every update is authenticated with the CreatorStudio Editor Sparkle Ed25519 key.

`scripts/release.sh 0.1.0 --unsigned` produces an ad-hoc signed, unnotarized Apple Silicon preview for early distribution. The preview omits bundled speech and Metal effects because the current release machine has Command Line Tools but not full Xcode. Users must approve its first launch through Control-click **Open** or **Privacy & Security → Open Anyway**. A future Developer ID release uses the same source, feed, and versioning path with signing, notarization, and stapling enabled.

Upstream Palmier signing, telemetry, Clerk, Convex, and Sparkle credentials are not used.

The source and DMG remain public under GPLv3. The local editor has no entitlement gate; hosted provider services authorize their own account-scoped requests.

## Rollout and verification

All hosted endpoints remain behind `CREATORSTUDIO_EDITOR_API_ENABLED`. Deployment order is Imager, CreatorStudio, then ClickCampaigns, followed by production rejection-path, catalog-version, secret-redaction, and representative-job checks before enabling the desktop client.

Desktop verification requires full Xcode for macOS 26, then:

```bash
swift build
swift test
swift build --traits BundledSpeech
```

Manual verification covers unrestricted editor access, one-time CreatorStudio pairing and relaunch restore, explicit disconnect, local Fal fallback, ElevenLabs credential lifecycle, selector exchange and confirmation, generation placement and undo, cancellation, relaunch recovery, project duplication, export, MCP discovery/receipts, and opening existing `.palmier` projects.

The home screen retains Palmier's original hosted sample-project source and `.palmier` compatibility. CreatorStudio Editor removes Palmier's first-run profile questionnaire; the editor tour and release notes remain independent flows.

## Production configuration

- Imager, CreatorStudio, and ClickCampaigns are deployed behind `CREATORSTUDIO_EDITOR_API_ENABLED` with server-only Ed25519 keys.
- CreatorStudio-to-Imager service authentication and the CreatorStudio Editor Sparkle update key are configured independently.
- The initial public release is an unsigned preview. A CreatorStudio Apple Developer ID identity and notarization profile remain optional future inputs for a standard double-click installation experience.
