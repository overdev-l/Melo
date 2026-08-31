# Contributing

Thanks for helping improve Melo.

1. Use macOS 14 or newer with Xcode 15.3 or newer.
2. Run `swift test` before submitting a change.
3. Build with `./scripts/build-app.sh` and validate with
   `./scripts/verify-app.sh`.
4. Keep cleanup and maintenance changes preview-first and recoverable.
5. Do not install the privileged Helper or write AppleSMC keys in automated
   tests. Real hardware tests require explicit authorization and must follow
   `HARDWARE_VALIDATION.md`.

For larger behavior or safety changes, open an issue first and describe the
user-visible outcome, failure recovery, and test plan.
