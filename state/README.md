# Runtime state

Pids, ports, generated configs and logs. Gitignored and safe to delete while the
services are stopped: `ops/install.sh up` recreates it.

`state/ops/` may contain secrets (the border key and ingress token). Never copy a
generated config into a tracked file.
