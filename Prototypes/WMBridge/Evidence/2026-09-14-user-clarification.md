# Trial input clarification

On 2026-09-14, the user confirmed that they did not switch Desktops manually
during the ATE-40 trials.

The earlier question described an active Desktop change, but the unexpected
observation was a display identifier change. The experiment itself also issued
documented Desktop navigation commands. The user's clarification excludes
manual Desktop switching by the user as an explanation; it does not establish
the cause of the display identifier changes or attribute them to WMBridge.

This supplements the original findings without changing the observed verdict:
the two returned type-0 Space IDs could not be entered through the tested native
navigation paths, and both were subsequently removed.
