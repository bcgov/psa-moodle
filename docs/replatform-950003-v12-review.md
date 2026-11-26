# Review of replatform 950003 DRAFT v1.2

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v1.2, commit `e4b302c44bd315a1f00de4679223b7d99464e12d`.
- **Date:** 2026-11-26.
- **Reviewer:** Codex.
- **Disposition:** Continue the replatform and scoped work in dev. Pass A supports advancing to Pass B preparation and controlled data-copy/rollback exercises, but I would not execute the complete Pass B sequence as written. Resolve the session/cache design gates, the missing CP3 egress profile and the rehearsal capacity plan before their dependent exercises. Test and production cutovers remain no-go until the existing exit gates pass.

The underlying migration strategy still makes sense: preserve legacy, copy data, keep rollback independent of the new
application, and treat a post-commit return as another migration. Pass A materially strengthens confidence in the
implementation. The findings below do not justify abandoning that strategy.

There are **eight major findings and one minor finding**. Several concern the proposed design, which v1.2 correctly
identifies as unbuilt; they are requirements for accepting that design, not claims that it has already failed in production.

## Scope and verification

I read the review instructions first, then §0.10, and checked the relevant safety rules, implementation, rehearsal and
cutover procedures against this repository and the two requested sibling repositories:

- `../moodle-nginx`, checkout `c167656ada8ff45fbb747da8a8b8f5fb91e02a31`;
- `../platform-developer-docs`, checkout `a82ae4ecea85c1c6ee78bd230e7e6a4bc1431008`.

For Moodle behavior absent from those checkouts, I inspected upstream source at the exact prod and dev commits recorded
in `ops/replatform/exact-code.json`, rather than assuming current upstream behavior. I also consulted PostgreSQL 15 and
k6 primary documentation, linked beside the relevant conclusions.

The review began as a desk review. During it, the owner explicitly authorized **read-only `oc` investigation**. Checks
on 2026-11-26, approximately 17:20–17:33 UTC, inspected dev resource definitions, quotas, existing backup logs and
statuses, selected application configuration/source checksums, and PostgreSQL settings and aggregate session counts.
SQL ran directly through the driver in a read-only transaction, without bootstrapping Moodle. Test/prod inspection was
limited to quota reads. No credentials, session payloads or personal records were printed.

Local Helm renders verified the Pass B/C storage arithmetic and the precommit PHP egress rules. No cluster resources,
application configuration or data were changed; no load, failover, restore or advisory-lock experiment ran on the
cluster. The only repository change is this review. A disposable local PostgreSQL lock experiment could not start
because the installed PostgreSQL binary lacks its ICU dependency; V1202 rests on source and documented lock semantics,
not a claimed runtime reproduction.

## Findings

Each row follows the requested `ID | severity | section and step | concrete failure scenario | suggested change` format.
Repository line references refer to `e4b302c`.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V1201 | major | §0.10 proposed cache design; §9 cache-failure acceptance | Moving sessions to Postgres does not make an unavailable Valkey equivalent to an empty cache: Moodle's pinned Redis store catches connection-establishment failures, but ordinary `get`, `get_many` and `set` operations can propagate a connection exception after initialization. A pod kill during an authenticated request can therefore still fail that request. | Keep the proposed in-flight kill test, add sustained unavailability and recovery under representative traffic, and make the design decision depend on those results. Do not approve a single instance under the current zero-error promise merely because sessions moved; choose a demonstrated resilience mechanism, a cache configuration that meets the speed bar without this dependency, or an explicitly accepted bounded interruption. |
| V1202 | major | §0.10 database sessions; §8.1 C8 lock; `scripts/ops/moodledata-backup.sh:36`, `:73` | The backup takes the single-bigint advisory lock `727368`; Moodle's PostgreSQL session handler takes that same lock form using the session row ID. A session with ID `727368` can make a backup exit successfully as though another backup owns the lock, or wait behind the backup until its session-lock timeout. | Give the backup a separate two-integer lock namespace, distinct from Moodle's general-purpose lock namespace too; update ownership checks to identify the complete lock key. Test a matching session ID alongside two backup contenders before enabling database sessions with nightly backups. |
| V1203 | major | §0.10 session recovery/cutover; S12; §13–14; `scripts/ops/restore-paired.sh:146` | With database sessions, physical backups contain authenticated `mdl_sessions.sessdata`. Restoring a point before logout can revive an otherwise unexpired session whose cookie was retained. The restore checks never invalidate sessions, and S12's statement that sessions are excluded becomes misleading. Switching between legacy Redis and database sessions also has no explicit reauthentication procedure. | Specify intentional reauthentication for restored copies and backend transitions. Invalidate destination sessions before admitting users, record the resulting expected difference, and test old cookies after logout/restore, cutover and return. Keep comparison evidence and the frozen legacy baseline intact; do not purge a shared legacy store as a shortcut. |
| V1204 | major | §9 Pass B CP3; §13.2 SSO check; `.github/workflows/deploy-950003.yml:156` | The runbook requires an HTTPS-capable CP3 profile, but the workflow's precommit profile always disables external egress, including when `site_host=public`. Changing wwwroot does not let PHP exchange the OAuth authorization code with SSO. The workflow's available way to enable that egress is `commit`, which also enables outbound integrations and cron before CP3 can pass. | Add an explicit SSO-capable review profile or equally explicit approved values step: reviewer restrictions retained, outbound guard on, cron off, and the required SSO egress allowed. Verify SSO and the continued email/ELM fence before recording S11. |
| V1205 | major | §0.10 production-shaped load test; §9 Pass B failover, Pass C storage/restore | Both checked-in dev overlays inherit one PostgreSQL instance, so they cannot perform the promised failover between instances. Raising Pass C to three instances makes its release 32 GiB; with the 4 GiB fixture it needs 36 GiB against 34.66 GiB available after Pass A removal. Even removing Valkey's 1 GiB leaves 35 GiB. Separately, the single-instance restore budget omits the restore cluster's own 1 GiB repository. | Write and render explicit HA/load/restore states, with replica counts and all retained PVCs. Sequence teardown/recreation or obtain capacity before those states run. Budget the restored repository and admitted compute too. Any dev scaling exception must name workloads and its undo; preserve the prohibition on scaling/restarting Galera. |
| V1206 | major | §0.10 performance plan, step 2; platform load-test requirements | A dev-only, internally generated load test can still run without the platform scheduling approval required by the supplied platform docs. The runbook's general 17:00 window is also earlier than the documented weekday load-test start time. | Add the Platform Services review/scheduling gate, a weekday start after 17:30 or a weekend slot, an available namespace administrator, and the required traffic-origin, ramp, duration, dependency and abort details. Keep the load generator time-bound at the pod level. |
| V1207 | major | §0.10 load scenario and pass criteria | “1,500 VUs with think time” leaves transaction rate, user/session distribution and application success undefined. A slower closed workload reduces its own request rate; a redirected login page or rejected forum/quiz submission can return HTTP 200. A green run can therefore represent materially less successful work than legacy. | Fix the scenario mix, pacing and minimum successful throughput; use independent synthetic identities/cookie jars and validate persisted forum/quiz results. Compare per-transaction latency and throughput on reset-equivalent data, record generator saturation and dropped work, and include normal-load and burst cases. |
| V1208 | major | §0.10 owner's speed bar; performance plan steps 1–3 | Service-level HTTP timings and a relative comparison to legacy dev do not establish the owner's roughly 200 ms browser experience. Both dev stacks could be slow, or one expensive authenticated page could regress while an aggregate p95 passes. Testing only dev's newer build/data also misses target-specific behavior. | Define the browser timing metric and an agreed absolute budget per representative page, alongside the relative 20% limit. Keep authenticated browser probes through representative Routes, including under load, and repeat target-page checks with each Pass C image/data set. Report per-page warm/cold results; do not equate HTTP duration with full browser load time. |
| V1209 | minor | §0.9 exporter decision; §0.10 load diagnostics; `chart/psa-moodle/templates/monitoring.yaml:137` | The statement that PHP-FPM metrics are unused by alerts is incorrect: `PHPFPMQueueSaturated` and `PHPFPMNoActiveWorkers` remain rendered and deployed while their exporter and scrape configuration are disabled. These rules cannot provide the intended PHP queue warning from this deployment. | Correct the statement and condition/remove the inactive rules, or supply a maintained metrics source. Give the performance exercise an explicit way to measure PHP worker/queue pressure without restoring the rejected exporter image. |

## Answers to the four §0.10 questions

### 1. Do Pass A's results support starting Pass B?

**Yes, with bounded scope.** Coexistence, image pulls, backup-role provisioning, actual backup publication, the recorded
empty paired restore, and infrastructure fencing are useful prerequisites. The live reads corroborate the current
resource totals, policy configuration and successful backup Jobs. I would continue preparation and individually
approved dev exercises using the existing safety gates.

I would resolve V1204 before attempting CP3 and V1205 before claiming an HA rehearsal. The session/cache change needs
its own implementation review and targeted tests before the two clean Pass B runs certify that final configuration.
Successful rehearsals of the current Redis-session/file-cache stack do not certify the proposed configuration.
Resolve V1202 before running the proposed database sessions with the backup job, and settle V1203 before accepting a
session-bearing restored site. These changes need not reopen the already settled migration strategy.

For V1204, the local precommit render with a public wwwroot still grants PHP only DNS, Postgres and Valkey egress.
Moodle's OAuth client performs a server-side token exchange, so a working browser redirect alone does not complete the
SSO check. The inspected namespace policies supply no additional PHP HTTPS allowance.
[Pinned OAuth token exchange](https://github.com/moodle/moodle/blob/32d78752a002b2e5c9401e2039b39c853f254536/lib/oauthlib.php#L593).

### 2. Are Postgres sessions and cache-only Valkey the right call?

**Postgres sessions are a reasonable simplification to test. Cache-only Valkey is reasonable, but its proposed
availability guarantee is not established.** Removing a separate session-storage dependency is useful. The phrase
“add no new way to fail” is too strong: locking, additional database work and session restoration change failure behavior.

The pinned database handler uses the existing Moodle database connection. It locks by session record ID, and writes
base64-encoded session data when its content changes. Consequently, 1,500 logged-in browsers do **not** require 1,500
permanently open PostgreSQL connections, and the incremental write cost is not necessarily a full payload on every
request. Moodle already keeps session metadata in the database with other handlers.
[Pinned database session handler](https://github.com/moodle/moodle/blob/32d78752a002b2e5c9401e2039b39c853f254536/lib/classes/session/database.php#L147).

I would add these specific acceptance measurements to the existing dev matrix:

- **Locking and connection headroom:** simultaneous AJAX/quiz requests sharing one session, many independent sessions,
  a long request, worker termination and PostgreSQL failover. Measure lock waits and PHP queueing. Dev currently has
  `max_connections=100`, with three superuser-reserved slots; each PHP pod has `pm.max_children=20`. Three production
  PHP replicas permit 60 simultaneous workers, or 80 with one surge pod, before cron, backup and management connections.
  This is a budget to verify, not evidence that 100 is already insufficient. Keep the no-transaction-pooler assumption
  explicit because these are session-level advisory locks.
- **WAL and storage:** measure session-table/TOAST growth, vacuum behavior, WAL rate, replica lag and pgBackRest repository
  growth during realistic sessions and logins. Recalculate the test/prod repository budgets under the actual retention
  policy. The empty-site backup and a short stress run cannot establish eight days of recovery capacity.
- **Nightly pause:** distinguish browser sessions from database connections. Idle logged-in users should not prevent the
  current nonpersistent-connection drain. In-flight requests and lock waiters can. Exercise those cases with database
  sessions and prove bounded reopening, skipped-set alerts, and a restore of an actual session-bearing paired set.
- **Session lifecycle:** preserve normal quiz/course data, but deliberately require a new login after restore or a backend
  transition. Test a cookie saved before logout against an earlier restored recovery point. The restored target must
  reject it before general access is enabled.
- **Cache setup and recovery:** make the proposed configuration script repeatable on a fresh dataroot and after a paired
  restore. Verify the application-mode mapping, isolated prefixes and credentials, and both web and cron behavior.
  Regenerate configuration from the release inputs; continue excluding legacy `muc/config.php` from copies.

**A single Valkey is not yet acceptable under the stated “cold cache and no errors” criterion.** An empty, reachable
cache and a broken connection are different cases. The Redis store's initialization catches connection errors, but its
ordinary operations are not generally wrapped that way; the cache loader calls the store directly. This specifically
supports v1.2's insistence on testing requests already in flight. Also test a prolonged outage, reconnection, eviction
pressure and concurrent cache rebuilds. If introducing fallback, verify invalidation consistency across workers rather
than assuming a second store is automatically safe.
[Pinned Redis store](https://github.com/moodle/moodle/blob/32d78752a002b2e5c9401e2039b39c853f254536/cache/stores/redis/lib.php#L424),
[pinned cache loader](https://github.com/moodle/moodle/blob/32d78752a002b2e5c9401e2039b39c853f254536/cache/classes/cache.php#L507).

### 3. Is the performance plan enough, and are its criteria right?

**It is a sound starting comparison, but not yet a complete acceptance test.** Keeping load in dev, comparing the same
scenario on both stacks, and making a miss stop progression are appropriate. Recovering the original BlazeMeter plan
would help historical comparison, but is not necessary for a valid new A/B test. The resulting claim should describe
the new workload rather than asserting exact equivalence to the old 1,500-user result.

Use a reproducible workload specification: synthetic users with realistic enrollments, representative course sizes,
fixed read/write proportions, explicit think-time distribution, controlled login frequency, isolated cookie jars and
content assertions. Reset the synthetic writes between compared runs. Avoid making every user an administrator or
accidentally exercising one shared session. Keep SSO and external integrations out of the mass traffic; separately
exercise their normal user paths under the approved review controls.

Keep the 1,500-VU hold, but record successful transactions per second and establish a minimum workload rate. A closed
VU test is legitimate for a user-population model; it is insufficient by itself to promise a particular offered load
because slower iterations reduce arrival rate. Add a fixed-arrival workload if required to test that separate promise.
Also include the real peak of about 50 users and a login/quiz burst.
[k6 workload-model documentation](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/open-vs-closed/).

Apply latency limits **per transaction/page**, with a stated metric and sample count. Retain the proposed 20% relative
limit, but pair it with owner-approved absolute limits based on representative legacy pages. The approximate 200 ms
observation should not silently become the same limit for every quiz, report and download. Use p95 for the gate, and
report p99, errors and throughput so tail failures and omitted work remain visible.

The browser probe should remain separate from HTTP load metrics and run during the load as well as before it. Requests
through Services are useful backend measurements; they omit the public route/TLS/browser path. Specify host and scheme
handling, follow redirects deliberately, and confirm the expected stack and authenticated page answered. Use each
target's Pass C data/image for the final representative browser checks. Protocol-level k6 timings do not include the
browser's rendering work.
[k6 website-testing documentation](https://grafana.com/docs/k6/latest/testing-guides/load-testing-websites/).

“No errors” is appropriate for the defined steady-state workload, including application-level validation. Specify
separate expectations for intentional failover, cache outages and the nightly maintenance page; otherwise expected
fault-test responses and ordinary capacity failures become indistinguishable. Capture PHP queue/worker pressure,
database connections and waits, WAL/archive lag, memory and generator utilization alongside the timings.

The supplied platform documentation explicitly requires scheduling review even when the traffic originates internally.
The permitted weekday start is after 17:30, and a namespace administrator must be available. This is a prerequisite for
the future load test, not a request to perform or schedule it during this review.
[Platform load-test requirements](../../platform-developer-docs/src/docs/automation-and-resiliency/prepare-to-load-test-application-on-openshift.md).

### 4. Does Pass A's evidence support what §0.10 claims?

**It supports the narrow empty-install result; it does not establish the proposed production behavior.** The distinction
already made in §0.10 should be retained.

| Read-only check | Observed result | What it establishes |
|---|---|---|
| Dev long-running quota | 2,331m CPU and 6,760 MiB memory used | Matches the reported normal-state total. |
| Dev storage | 72,030 MiB allocated, including Pass A's 9 GiB | Removing the explicitly listed Pass A storage would leave 62,814 MiB allocated and 34.66 GiB free, as planned. |
| PostgreSQL topology | One instance, 2 GiB data PVC | Current Pass A is a single-instance deployment, not an HA demonstration. |
| Admitted PostgreSQL resources | Instance: 401m / 1,344 MiB; repository host: 100m / 512 MiB | Confirms the operator-side resource additions used in the runbook. |
| Scheduled moodledata backup | Existing log reports a 9-second drain/pause, four inventory hashes, zero new files copied, successful gate and publication | Corroborates the empty-site result; does not predict the first production-sized copy or a busy drain. |
| Backup Jobs | Manual integrity checks, manual/scheduled file backups and recent incrementals succeeded | Supports the reported successful executions; does not independently replay their correctness checks. |
| Session configuration | Live PHP still selects `\core\session\redis`; PostgreSQL session table had zero rows at inspection | Confirms the proposed session change is not deployed; the current state does not test database-session restoration or contention. |
| Egress configuration | App has DNS/Postgres/Valkey rules; ops API rule is `142.34.151.0/24:6443` | Matches the narrowed configuration; also confirms there is no current SSO egress allowance for PHP. |
| Prod quota | Still 4 CPU / 96 GiB; 2,975m CPU and 95,332 MiB storage allocated | The requested temporary increase remains a prerequisite. |

The historical paired restore, pod-kill timings, alert delivery and fence/undo timings remain evidence reported by the
runbook's author; this review did not rerun them or inspect the owner's private evidence package. The recorded paired
restore is materially better evidence than a green backup Job. Its scripted check is nevertheless a CLI check; the
script itself says a login check needs a temporary release, which belongs in Pass C.

A primary restart on a one-instance cluster, even with later timelines, does not demonstrate promotion of a standby
and recovery of an older set after that promotion. Likewise, ordinary pod deletion does not establish voluntary
eviction/PDB behavior. Do not use those Pass A observations to discharge the outstanding multi-instance exercises.
Repository peak usage under the retained production workload remains outstanding too. The HTTP/2 explanation for the
cold-page timing gap should remain a hypothesis until a controlled browser comparison establishes it.

## Evidence for the two less obvious implementation findings

**V1202: the lock collision is exact, not a general concern about session locking.** The backup calls
`pg_try_advisory_lock(727368)` and holds it through completion. The pinned PostgreSQL driver calls
`pg_advisory_lock($rowid)` for a database session. Both use the same single-bigint key space in the same database;
different database roles do not separate it. PostgreSQL's two-integer form occupies a different key space. Moodle's
general lock factory already uses that form with its own namespace, so the backup should choose another namespace and
verify both key parts. This affects a specific session ID, not every user, but it is avoidable before adoption.
[Pinned PostgreSQL session locks](https://github.com/moodle/moodle/blob/32d78752a002b2e5c9401e2039b39c853f254536/lib/dml/pgsql_native_moodle_database.php#L1590),
[Moodle general lock namespace](https://github.com/moodle/moodle/blob/32d78752a002b2e5c9401e2039b39c853f254536/lib/classes/lock/postgres_lock_factory.php#L24),
[PostgreSQL 15 advisory-lock semantics](https://www.postgresql.org/docs/15/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS).

**V1205: the missing replica/storage states are visible in local renders.**

| Render/state | PostgreSQL instances | New storage requested |
|---|---:|---:|
| Checked-in Pass B | 1 | 18 GiB |
| Pass B with three PostgreSQL instances | 3 | 24 GiB |
| Checked-in Pass C | 1 | 24 GiB |
| Pass C with three PostgreSQL instances | 3 | 32 GiB |
| Three-instance Pass C plus legacy fixture | 3 | 36 GiB |
| Checked-in single-instance Pass C plus paired restore, fixture removed | 1 source + 1 restored | 34 GiB |

The final row is 24 GiB source + 4 GiB restored database + 5 GiB restored files + **1 GiB restored repository** from
`restore-paired.sh:75`. It still fits the stated 34.66 GiB headroom, but with about 0.66 GiB spare, not 1.66 GiB.
Keeping three source instances while doing that restore would require 42 GiB. Removing the proposed Valkey PVC saves
1 GiB in each affected state; it does not make the three-instance fixture/restore combinations fit. Scaling a database
down is not evidence that its PVCs have been reclaimed.

## Recommended continuation

1. Correct the CP3 review profile and write the explicit rehearsal resource states and load-test specification.
2. Implement the proposed session/cache changes, including a separate backup lock namespace, session invalidation on
   restored targets, and repeatable cache configuration. Prove their targeted failure cases in dev.
3. Run the approved performance comparison and the complete two clean Pass B rehearsals against the chosen final
   configuration, then Pass C for each target with measured restore, return, backup-pause and storage results.
4. Consider test cutover only after those gates pass; retain the runbook's separate production gates and quota prerequisite.

I would continue investing in this plan. I would not turn Pass A's success into approval of the unbuilt session/cache
design or a test/production cutover.
