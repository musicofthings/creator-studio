# Optional AI gateway

This service is deliberately outside the critical path. The app remains useful without it.

The checked-in provider is deterministic and local to the service process so tests never send content to a third party. A production provider adapter must:

- validate authentication and a signed consent receipt;
- send only declared data classes;
- use schema-constrained output;
- validate returned ranges/evidence before responding;
- avoid raw content in logs and delete transient inputs/results by policy;
- keep provider API keys server-side.

The entrypoint refuses to start without `GATEWAY_AUTH_TOKEN`; there is no unauthenticated mode outside tests, which pass `authToken: null` explicitly. A static bearer token is still only a local-development stand-in for real identity and consent-signature validation.

Request bodies are validated against a JSON Schema that mirrors `contracts/openapi.yaml`, with Ajv type coercion disabled so a mistyped field is rejected rather than silently converted. Cross-origin requests are denied unless the origin appears in `ALLOWED_ORIGINS`; the wildcard is never sent.

Set `GATEWAY_VERIFY_INPUT_HASH=1` to require that `inputHash` match the submitted transcript. The canonical form is a JSON array of `[startUs, endUs, text, speaker]` tuples in submission order (see `canonicalTranscriptHash`). It is opt-in until a client implements it.

For an OpenAI implementation, follow the official [file transcription](https://developers.openai.com/api/docs/guides/speech-to-text) and [structured output](https://developers.openai.com/api/docs/guides/structured-outputs) documentation. Select models in server configuration and evaluation; do not bake a model name into the project format.

```sh
npm install
npm run check
npm run dev
```
