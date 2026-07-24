# DDNS Desired State File

This slice set moves DDNS desired state out of environment variables and into a file-backed contract that can be edited, restarted, and reloaded without rediscovering the shape of the config.

The runtime record snapshot remains separate in `DDNS_RECORD_SNAPSHOT_PATH`.

## Slice Order

1. `00-conventions.md`
2. `01-desired-state-store.md`
3. `02-monitor-consumes-desired-state.md`
4. `03-verification.md`

## What This Set Achieves

- A/AAAA/CNAME desired state is owned by a file instead of env vars.
- Operational flags that affect DNS planning are owned by the same file.
- `CLOUDFLARE_API_TOKEN` stays in env because it is a secret.
- First boot can seed the file from existing env config, but later boots use the file as the source of truth.
- Reload remains explicit. No file watcher or automatic merge loop is introduced in this set.

## Dependencies

- Read `00-conventions.md` before any implementation slice.
- Merge `01-desired-state-store.md` before `02-monitor-consumes-desired-state.md`.
- Use `03-verification.md` as the durable gate for the whole set.

