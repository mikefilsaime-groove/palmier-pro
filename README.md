# CreatorStudio Editor

CreatorStudio Editor is a native macOS video editor built from the GPLv3 Palmier Pro codebase. It preserves Palmier's local timeline, editing, export, Agent, and MCP capabilities while replacing Palmier-hosted accounts, credits, and generation with Scale Plus GodMode and bring-your-own-key media providers.

The app requires macOS 26 (Tahoe) on Apple Silicon.

## Download the Mac preview

[Download CreatorStudio Editor for Mac](https://github.com/mikefilsaime-groove/palmier-pro/releases/download/creatorstudio-v0.1.0/CreatorStudioEditor.dmg)

This first public preview is ad-hoc signed but not Apple-notarized. Drag the app to Applications, then Control-click **CreatorStudio Editor**, choose **Open**, and confirm. If macOS still blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**.

CreatorStudio Editor does not currently support Intel Macs or Windows.

## Media generation

- Video and image jobs prefer the authenticated user's encrypted Fal.ai key stored by CreatorStudio.
- A Fal.ai key stored in this Mac's Keychain is available only when CreatorStudio confirms that the user has no key on file.
- Text-to-speech, sound effects, music, and video-to-music use the user's ElevenLabs key stored in Keychain.
- The video model picker includes an authenticated **Help me choose** flow backed by CreatorStudio's live catalog.
- Local transcription remains available. Palmier's hosted generation, cloud transcription, account, credit, telemetry, feedback, and update services are not used.

## Access

An active ClickCampaigns GodMode entitlement unlocks the complete application. If GodMode is inactive, users can still open, edit, save, and export existing projects, but cannot create projects, generate media, use the in-app AI agent, or invoke mutating MCP tools.

Authentication requires the user's already-authenticated ClickCampaigns GodMode MCP. CreatorStudio Editor displays a short-lived pairing code; the MCP approves it and ClickCampaigns issues an app-specific token stored in Keychain. The MCP's own credential is never read or copied. A successful entitlement carries a signed seven-day offline lease for service outages; an explicit inactive or revoked response always fails closed.

## MCP server

While the app is open, CreatorStudio Editor exposes MCP over HTTP at `http://127.0.0.1:19789/mcp`.

Claude Code:

```bash
claude mcp add --transport http creatorstudio-editor http://127.0.0.1:19789/mcp
```

Codex:

```bash
codex mcp add creatorstudio-editor --url http://127.0.0.1:19789/mcp
```

Cursor:

```json
{
  "mcpServers": {
    "creatorstudio-editor": {
      "type": "http",
      "url": "http://127.0.0.1:19789/mcp"
    }
  }
}
```

The app also bundles a Claude Desktop connector under **Help → MCP Instructions**.

## Development

```bash
swift build
swift test
swift build --traits BundledSpeech
```

The Swift executable and `.palmier` package format intentionally retain their upstream identifiers for project compatibility and lower-conflict upstream merges. See [the architecture and synchronization plan](docs/PALMIER_CUSTOM_PLAN.md) and [contribution guide](CONTRIBUTING.md).

`main` is reserved as a clean mirror of `upstream/main`. CreatorStudio-specific work and releases live on `fal-integration`.

## Upstream and license

CreatorStudio Editor preserves the history of [Palmier Pro](https://github.com/palmier-io/palmier-pro), originally created by Palmier, Inc. Source and distributed builds are licensed under [GPLv3](LICENSE).
