# Project instructions

## Environment roles (read before touching any cluster)

| Environment | Users | Treat as |
|---|---|---|
| `950003-prod` | Learners | Production |
| `950003-test` | Course developers and instructional designers, who build courses there | **Production** |
| `950003-dev` | Nobody; ephemeral | The only cluster target for experiments |

- Never run anything destructive, experimental, load-generating or untried against test or prod: no load tests, restore or failover drills, deliberate-corruption tests, untested scripts or configuration changes. Prove them in dev or locally.
- Do not change anything on any OpenShift cluster without explicit human approval for that specific action. Read-only inspection is fine.
- A change to test or prod needs a fresh verified backup (database and moodledata), an agreed window, maintenance mode, a go/no-go check and a written rollback.
- Keep test and prod on the identical Moodle build and plugin set. Courses move test → prod as `.mbz` backups, which cannot restore into an older Moodle.

These roles carry over to any namespace that takes over test or prod, including the replacement's own `-test`. Full context: README.md, "Environment roles: read this first".
