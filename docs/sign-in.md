# ChatGPT plan sign-in

Kiln uses the official open-source Sign in with ChatGPT flow. This is separate from an OpenAI API-key profile and depends on the user's eligibility, granted scopes, available models and ChatGPT usage limits. It does not provide access to ChatGPT conversation history.

## Connect an account

Initialize [Vault](vault.md) first. From an administrator session:

```text
ai login chatgpt
ai login status ATTEMPT_ID
ai accounts
ai models ACCOUNT_ID
ai use chatgpt ACCOUNT_ID MODEL_SLUG --new-context
ai ask "Report the current system state"
ai usage
```

Use the attempt and account IDs returned by Kiln, and a model slug from `ai models`. To choose a callback port, use `ai login chatgpt 14555`. For an existing registration, use `ai login chatgpt-account ACCOUNT_ID` or `ai login chatgpt-account ACCOUNT_ID 14555`. Cancel with `ai login cancel ATTEMPT_ID`; sign out with `ai logout ACCOUNT_ID`.

The command displays **Continue with ChatGPT** and an authorization URL. Kiln starts an HTTP callback listener bound only to `127.0.0.1`, then provides the authorization URL. Open that URL on the same machine, authenticate with OpenAI and grant the permissions you want. For a remote server, establish an SSH local forward to the selected callback port before opening the URL locally. For example, use the host’s OS SSH service: `ssh -N -L 14555:127.0.0.1:14555 user@host`, then start `ai login chatgpt 14555` in Kiln. If forwarding through Kiln itself, its bastion destination allowlist must explicitly allow that loopback port. Do not expose the callback listener publicly.

The browser returns to `/auth/callback`. Check the sign-in attempt status in Kiln. A received callback is not proof of successful sign-in: Kiln must exchange the code, verify the signed ID token and save the credentials. Choose a model from the account's live model catalog before selecting its profile.

Kiln requests a dynamically registered public client. No client secret, partner API key or imported credential from another application is used. The host ID stays stable across restarts. Each account retains its issued client ID, so subsequent authorization reuses its registration. The browser account selector is used on reauthorization; tokens are never embedded in a URL printed to the terminal.

Erebine remains the normal API-backed interface. Connecting a ChatGPT account does
not select it or forward an existing Erebine conversation. Select it explicitly
with `ai use chatgpt ACCOUNT_ID MODEL_SLUG --new-context`. Return to a saved
Erebine profile with `ai profile use NAME --new-context`. Both routes use the same
Kiln tools and approval rules, without automatic billing or provider fallback.

`ai status` shows the active authentication/billing mode and destination. The chat
header identifies the provider/profile and model. `ai usage` returns
https://chatgpt.com/settings/usage for managing ChatGPT's app/account allowance.
A plan-limit error links there without inventing a reset time or retrying the
same limit failure automatically.

## Identity and credential boundaries

Each account is bound to the initiating Kiln identity name and SSH-key fingerprint (or the separate local-console identity). Replacing an SSH key does not transfer the previous key's accounts. Other identities cannot select it, obtain its token or sign it out through the account API. Credentials are encrypted in Kiln Vault, under an account-specific grant. The local account index contains public registration metadata only. JWT signature, issuer, audience, expiry, nonce and returning account identity are checked before accepting credentials. OAuth state is random, expires in ten minutes and is consumed once.

Token refresh is guarded against concurrent rotation and persists the renewed bundle together. Sign-out attempts remote revocation and clears local credentials while retaining registration metadata. If remote revocation cannot be confirmed, Kiln reports that fact; disconnect the application from ChatGPT settings to confirm remote removal.

## Inference contract

Subscription profiles use `https://api.openai.com/v1/responses`, `store: false`, `stream: true`, developer instructions and namespaced function tools. Unsupported preview parameters such as `max_output_tokens` are omitted. Kiln's existing bounded output and tool authorization checks still apply. A completed stream is required before tool calls become executable. Encrypted reasoning items are carried forward as opaque provider context; their contents are not displayed.

## Validation boundary

Offline protocol tests can verify callback binding, PKCE, token signatures, replay rejection and request formatting. Authenticated ChatGPT sign-in and inference remain pending user consent in this release validation. Actual eligibility, consent, model availability and inference require the user's browser authorization and a completed live response. Kiln does not infer subscription access from a successful identity token alone.

Official references:

- [Open-source registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts, refresh and sign-out](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

## Grok device sign-in

The separate [Grok CLI worker](grok-cli.md) accepts these administrator commands:

```text
ai login grok /absolute/path/to/grok
ai login grok-status ACCOUNT_ID
ai accounts grok
ai headless account ACCOUNT_ID MODEL "Briefly describe your capabilities"
ai login grok-cancel ACCOUNT_ID
ai logout grok ACCOUNT_ID
```

The status command supplies the verification instructions from the vendor's device flow. Only the initiating identity can inspect or use that account. Kiln does not import an existing desktop login. The worker uses macOS sandbox-exec or Linux bubblewrap with working user namespaces. It remains inference-only, with no host workspace or Kiln mutation tools. Authenticated device sign-in/inference awaits user consent and live verification.
