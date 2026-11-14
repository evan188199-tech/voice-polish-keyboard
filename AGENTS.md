# Repository safeguards

- Diagnose connectivity without changing credentials, proxy, TLS verification, or security settings. Run `python3 scripts/doctor.py`; treat failures as observations, not root causes.
- For the original authorized branch, `python3 scripts/verify_original_branch.py` is a read-only completion gate. Only its exact remote match permits a success claim. Never push, merge, or create a PR without the applicable authorization.
- Use `scripts/install_device.sh` only with an explicit device, development team, and clean source commit. Do not enable automatic provisioning updates or device registration. Distinguish build, installation, launch, and device acceptance.
- Run `python3 Tests/InstallSafety/test_install_safety.py` and `python3 Tests/EngineeringGuardrails/test_guardrails.py` for changes to these gates. Mock results are not real network, Xcode, or device validation. See `docs/engineering-guardrails.md`.
