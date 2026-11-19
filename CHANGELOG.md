# Changelog

## 0.1.0 (2026-11-19)

- Initial release covering the TypeSafe API v0.2.0: `POST /v1/systemone` and `GET /v1/models`.
- Noul, Choice, Score, and Box questions with typed answers.
- Images through multipart or base64, with automatic danger-zone headers.
- gzip/zstd request compression, retry policy, typed errors, and response validation.
- The API key, model, and base URL load automatically from Rails credentials (`typesafe:` or `typesafe_api_key`).
