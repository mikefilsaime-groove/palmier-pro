# CreatorStudio Editor

CreatorStudio Editor is a native macOS video editor built from the GPLv3 Palmier Pro codebase. It preserves Palmier's local timeline, editing, export, Agent, and MCP capabilities while replacing Palmier-hosted accounts, credits, and generation with bring-your-own-key media providers.

The app requires macOS 26 (Tahoe) on Apple Silicon.

## Download the Mac preview

[Download CreatorStudio Editor for Mac](https://github.com/mikefilsaime-groove/palmier-pro/releases/latest/download/CreatorStudioEditor.dmg)

This first public preview is ad-hoc signed but not Apple-notarized. Drag the app to Applications, then Control-click **CreatorStudio Editor**, choose **Open**, and confirm. If macOS still blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**.

CreatorStudio Editor does not currently support Intel Macs or Windows.

## Media generation

- CreatorStudio account sync is a one-time, optional connection used only to load the Fal.ai catalog and access the user's encrypted CreatorStudio Fal.ai key.
- The connection token is stored in this Mac's Keychain and restored after relaunch. The app does not repeatedly check GodMode entitlement or ask the user to pair again.
- A Fal.ai key stored locally in Keychain is used when the connected CreatorStudio account has no Fal.ai key on file.
- Text-to-speech, sound effects, music, and video-to-music use the user's ElevenLabs key stored in Keychain.
- The video model picker includes **Help me choose**, and Settings links to the [CreatorStudio Video Selector Guide](https://creatorstudio.gg/video-selector).
- Local transcription remains available. Palmier's hosted generation, cloud transcription, account, credit, telemetry, feedback, and update services are not used.

## Access and optional CreatorStudio connection

Anyone who downloads CreatorStudio Editor can use the complete editor. No account, subscription, entitlement, or authentication is required to create, open, edit, save, duplicate, export, use the Agent, or invoke MCP tools.

Fal.ai models use an optional one-time CreatorStudio account connection. CreatorStudio Editor displays a short-lived pairing code, and the user authorizes it with either the ScalePlus ProMax SuperPowers Plugin or ClickCampaigns GodMode MCP. ClickCampaigns issues an app-specific token that is stored in Keychain until the user explicitly disconnects. The MCP credential itself is never read or copied, and no seven-day lease or recurring desktop entitlement check is used.

Codex GPT Image 2, direct OpenAI or Anthropic Agent keys, and ElevenLabs work independently of that CreatorStudio connection.

## Updates

The packaged app checks the CreatorStudio GitHub Sparkle feed when it launches and again while active when the previous check is more than one hour old. When a release is available, an **Update** button appears in the Home sidebar and project title bar. **CreatorStudio Editor → Check for Updates…** and **Settings → General → Software Updates** can also start a check manually.

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
