# Third-party notices

Melo includes a minimal, adapted subset of the `SMCCore` Swift implementation
from [`leaperone/smctl`](https://github.com/leaperone/smctl), pinned to commit
`d5156b04cd0d998f66d0f637236d0cb874ad898d`. Only the AppleSMC connection,
typed value decoding, runtime key discovery, and fail-safe fan control code is
included; the upstream daemon, telemetry, command-line parser, and unrelated
dependencies are not bundled.

Copyright (c) the smctl contributors. Licensed under the MIT License. The
upstream license is available at
<https://github.com/leaperone/smctl/blob/d5156b04cd0d998f66d0f637236d0cb874ad898d/LICENSE>.
