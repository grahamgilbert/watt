# Login item validation

Validated on 2026-11-06 with the actual running PR app, signed using an existing Apple Development identity. The read-only `--diagnose-login` command reported eligibility, native `SMAppService.mainApp` status and the setup marker; the Preferences control and macOS Login Items were also exercised directly.

The signed app was eligible before its first launch. Native raw status `0` means `notRegistered`; `1` means `enabled`.

| Action | Native status | Setup marker | Preferences |
| --- | --- | --- | --- |
| Before first launch | 0 | Absent | App not launched |
| First real app launch | 1 | True | On |
| Click Open at login off | 0 | True | Off |
| Quit and relaunch | 0 | True | Remains off |
| Click Open at login on | 1 | True | On |
| Remove only the test app's Open at Login entry in macOS System Settings | 0 | True | Off after app activation |
| Quit and relaunch again | 0 | True | Remains off |

The actual signed, enabled Preferences window is captured in [the after screenshot](design/pr-2-open-at-login-after.png).

## Cleanup and limits

The test login entry was removed, the test app was quit and retired, and the test-created setup marker was restored to its original absence. Only the original Login Items entries remained, and the original installed Watt app was resumed. No signing identity was imported or exported, and the energy helper's registration and security checks were unchanged.

App copies with the same bundle identifier can share CFPreferences even when history storage uses an alternate home. The original preference state was checked before restoring the test-created marker.

A complete macOS logout/login cycle and reboot were not performed.
