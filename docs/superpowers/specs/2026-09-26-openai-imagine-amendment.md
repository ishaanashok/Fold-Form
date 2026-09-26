# OpenAI Imagine provider amendment

The user changed Imagine from NVIDIA NIM/GLM-5.3-Flash to OpenAI. This amendment supersedes the
provider, model, credential and cloud-disclosure sections of the earlier hands-free design. The
editable CAD document, `ImagineGenerating` boundary, typed `ImaginePlan`, validator, revision check
and atomic executor remain unchanged.

On Generate, `OpenAIImagineClient` sends the prompt, normalized sketch coordinates, sketch PNG,
current design PNG, symbolic body descriptions, selected body, units and deletion choice to
`https://api.openai.com/v1/chat/completions` using `gpt-6-sol`. It requests JSON text with an
8,192-token completion limit and low reasoning effort. The result is parsed and validated before
any document mutation. If validation rejects a plan, the client sends the validation reason in one
corrective request with medium reasoning effort and validates the replacement; a second invalid plan
still changes nothing. The planning prompt distinguishes new geometry from edits and shows the
top-level target required for every edit.
Opening Imagine, dictating, or sketching sends no cloud request.

A finished voice request to create a designed object such as “make a table” opens Imagine with the
exact transcript in its editable prompt. The editor stops voice listening before presenting the
sheet. The request changes no geometry and sends nothing to OpenAI until Generate is tapped.
Unrecognized speech that is not a design request still asks for clarification.

`KeychainStore` uses a distinct `openai-imagine` account under the existing Imagine service. The
app's key field saves or removes that credential. The key is only an Authorization bearer value;
it does not appear in the request body or repository. Missing, rejected, offline, timeout and
cancelled requests retain their existing user-facing error paths.

The later [Apple voice amendment](2026-09-26-apple-voice-amendment.md) replaces the Needle voice
runtime on all devices. It does not change Imagine's OpenAI request.

Verification: URLProtocol tests assert endpoint, model, images, bearer placement, error mapping
and cancellation without network. An authenticated model lookup and minimal JSON Chat Completions
request succeeded with the supplied key. The integrated change passed 415 FoldForm unit tests
(two skipped), the host credential scan, and Bitrig's built-in simulator build.

References: [OpenAI image input](https://developers.openai.com/api/docs/guides/images-vision),
[GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol), and
[JSON output](https://developers.openai.com/api/docs/guides/structured-outputs).
