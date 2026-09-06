# This repository is published, not authored

`action.yml`, `report-preview.sh` and `README.md` are copied verbatim
from `github-actions/report-preview/` in the churner monorepo, which is
where they are edited, reviewed and tested. Do not patch them here: the next
release overwrites the file, and the change would never have run against the
action's test suite (which executes `report-preview.sh` against a stub of
the tracker's own events route).

Released from churner monorepo commit `1905605`.
