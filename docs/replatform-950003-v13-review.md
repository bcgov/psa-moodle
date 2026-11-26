# Review of replatform 950003 DRAFT v1.3 (self-review)

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v1.3 with rule S16, commit `92c9595`.
- **Date:** 2026-11-26.
- **Reviewer:** Claude, the author of v1.3, reviewing its own work adversarially at the owner's request because no
  independent reviewer was available. **This is not an independent review.** It should not be cited as a second opinion.
  The next independent review should cover v1.3 and whatever Pass B finds.
- **Disposition:** **Do not build or install Pass B with v1.3 as it stands.**
  - Fix V1301–V1303 first. They are small code and configuration changes, but each one would otherwise put a defect into
    the rehearsal that certifies the configuration.
  - Correct the claims V1304 and V1307 disprove, and **correct the draft privacy note before it is sent** (V1307).
  - Resolve V1305, V1306 and V1314 before asking Platform Services to schedule the load test.
  - The session and cache direction itself holds up. The owner's single-Valkey decision stays sound once V1301 and V1302
    are fixed.

## Scope and verification

The review set out to break every claim §0.11 and S16 make. It checked them against:
- **Moodle 4.5 source:** the local copy of prod's exact code (`2024100711.04`). It covered the error handlers, the cache
  API (`core_cache\cache`, `factory`, `helper`, `config_writer`), the Redis store, the database session handler and the
  memory helpers.
- **The platform docs** in `../platform-developer-docs`.
- **Local renders** of the chart in every profile.
- **Read-only cluster and GitHub inspection:**
  - dev's role bindings, quotas and the legacy backup and Galera configuration;
  - legacy dev and prod workload shapes;
  - legacy prod Redis's `INFO memory`, `stats` and `keyspace`, with counts only and no keys read;
  - the SSO host's DNS;
  - `bcgov/moodle-nginx`'s environments, secret *names* and branches.

Nothing was changed on any cluster or repository. Names of people and secret values were not printed.

## Findings

Each row follows the `ID | severity | section and step | concrete failure scenario | suggested change` format.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V1301 | major | §0.11 cache design; `configure-cache.php` | Several **session-mode caches** subscribe to invalidation events: `core/coursecat`, `grade_categories`, `courseeditorstate`, `calendar_categories`, and the content bank and MoodleNet ones. With `default_session` they live inside the user's session, which is now in Postgres and survives a Valkey restart. The `core/eventinvalidation` records that tell them to refresh live in Valkey and don't survive. After a Valkey restart, or an outage during which invalidations go to the dummy store, a user keeps a stale course or category list, stale gradebook categories or stale editor state until they log out. Before v1.3, Redis held both, so a loss was consistent. §0.11's "never stale" is wrong | Map `MODE_SESSION` to `psa-valkey` as well (the Redis store supports it). Session caches and their invalidation records are then lost or kept together, as before, and session rows in Postgres shrink, which cuts database writes and WAL. Size check: legacy prod's Redis, holding sessions *and* caches, peaks at 37 MB, so 256 MB has room. Test in Pass B: change a category, restart Valkey, and check an open session sees the change |
| V1302 | major | `templates/valkey-workload.yaml` probes | Valkey's liveness probe is a **TCP check**, which passes while a hung Valkey still accepts connections, so a hung Valkey is never restarted. Readiness (`ping`) takes it out of the Service after about 15 s, and requests run uncached. But it **keeps its data**. Any invalidation attempted while it was out went to the dummy store and was lost, so when it answers again, those entries are stale (a changed setting or role definition, say) until the next purge | Make liveness `valkey-cli ping` (exec, timeout 2 s, period 5 s, failure threshold 3). A Valkey that stops answering is then restarted empty, so consistency comes back with it. Add a runbook step: after any incident where php lost Valkey while Valkey itself stayed up (a network partition), run `purge_caches.php` |
| V1303 | major | `config/php/php.ini`, `php-fpm.conf`, php resources | **Memory doesn't match legacy, in two ways.** (1) PHP's `memory_limit` is 512M, legacy's is **2048M**. Moodle's backup and restore raise only to `MEMORY_EXTRA` (`extramemorylimit`, 512M by default), so a large `.mbz` restore that works on legacy can fail on psa-moodle ("Allowed memory size exhausted"). Course developers depend on the test-to-prod `.mbz` flow (CLAUDE.md), and legacy's own mojibake `.mbz` script set 2048M. (2) The php pod's 1 GiB limit has to hold up to 20 workers at 512M each plus a 256 MB opcache. Legacy prod's php pods have **no memory limit** and 50 workers. Under the 1,500-user load, or one heavy request on a busy pod, the container is killed and every request on it fails | Parity first: `memory_limit = 2048M`, php requests 1 GiB, limit 3 GiB (quota counts requests; dev has 32 GiB). Measure worker memory in Pass B-HA and tune `pm.max_children` and the limit from the numbers. Add Pass C's largest real course `.mbz` restore as an explicit check |
| V1304 | major | §0.11 friendly page claim; `config/nginx/` | Moodle's normal exception handler sends **404**, not 500 (`core_renderer::fatal_error`). Only errors during `setup.php` (`bootstrap_renderer::early_error`) and PHP fatals produce 500. A Valkey failure partway through a page has three possible outcomes. (a) It's a PHP fatal, because the handler itself needs the string cache, and shows the friendly page; that matches the local test. (b) Moodle renders its own error page with a 404 and "Exception - read error on connection to psa-moodle-valkey:6379". (c) Output had already started, and the page is cut off. The claim "all shown the friendly page" was true of the local sample, not in general | Correct §0.11 and the Valkey decision text: the friendly page covers PHP failures and an unreachable or timed-out PHP, not every failure. In Pass B, count the outcomes when Valkey is killed under traffic (500 / 404 / truncated). Optionally, after the commit point, customise `error/generalexceptionmessage` so Moodle's own page reads politely in case (b). Don't intercept 404: Moodle uses it for every ordinary error, such as permissions or a missing course |
| V1305 | major | §9 Performance acceptance, workload path | "Against each stack's web Service, never a Route" doesn't work as written. Moodle checks the Host header against `wwwroot` (the local test hit exactly this redirect loop). With `sslproxy` and an HTTPS wwwroot, its session cookie is `Secure`, so JMeter talking plain HTTP to the Service never sends it back, and every user is logged out. Going through the Route instead runs into the IP allowlist (S15). In-cluster traffic reaches the router from Silver's shared egress addresses, which can't be allowlisted for a copy of real data | Decide the path, and prove it in Pass B-HA before scheduling. Recommended: a TLS-terminating sidecar in the generator pod (JMeter → `https://localhost` → the web Service over HTTP, with the wwwroot Host header). Moodle then sees the right host, cookies flow, and no Route or allowlist change is needed. Record that this leaves out the router, and keep the browser probe for the full path |
| V1306 | major | §9 Performance acceptance, comparison | **The A/B isn't like for like.** Legacy dev runs 1 php replica with a 1.5-core CPU limit; Pass B-HA runs 3 with no CPU limit, so "within 20% of legacy dev" compares different capacities. And the legacy side would run `maketestcourse --size=XL` (10,000 users and a course) and post forum replies **into legacy dev's own `moodle` database**. Legacy dev has no outbound guard, so its cron would email the forum notifications | Compare at equal shape: psa-moodle at Pass B's one php replica with the same CPU limit, against the legacy side. Run the 1,500-user absolute test at prod shape separately. Run the legacy side against a **disposable legacy fixture database** loaded from legacy dev's dump (the Pass C fixture machinery), with mail disabled there, never against legacy dev's own `moodle` |
| V1307 | major | S16 deletion; the draft note to PSA's privacy contact | **"Deleted and verified" can't be fully true as designed.** (1) Pass C's copies on `netapp-file-backup` (the pgBackRest repository, the moodledata backup volume, a restore's repository) are **backed up daily by OCIO and kept for 90 days** (`platform-storage.md`). Deleting the volumes leaves recoverable prod copies outside our control. (2) Galera's binary logs expire only when a log **rotates** (1 GB by default). In a quiet dev cluster with 5 nodes, "no binary log older than the drop" may not pass for weeks. Galera's write-set cache on each node also keeps fragments. (3) The platform's log store keeps request logs. The draft note says copies are "deleted afterwards ... including database logs" | Before Pass C: give Pass C's copies `netapp-file-standard` (no OCIO backup) through the overlay and the restore script. Pass B, on legacy dev's data, still exercises the backup class. Or keep the class and disclose the 90-day retention. Add `FLUSH BINARY LOGS` and `PURGE BINARY LOGS BEFORE NOW()` on all 5 Galera nodes to the deletion step, as an approved legacy dev change, and record the write-set cache as a known residue. **Correct the privacy note before sending:** state the residues and their retention |
| V1308 | minor | S12 H1 database-only recovery | Recovering only the database to within minutes, using the live files, brings back sessions that were logged out in that window. Only `restore-paired.sh` clears sessions | Add "clear `mdl_sessions`" to the H1 database-only recovery, as in every other restore (V1203) |
| V1309 | minor | `templates/job-install.yaml` | The installer runs `configure-cache.php` under `set -eu`. If it fails after a successful install, the Helm hook fails, the failed hook Job is never removed and holds the volume (Pass A's second undo), and `install_database.php` can't run again on the populated database | Make the step non-fatal: log a warning. The php pods apply it at their next start, and `deploy-950003`'s `--check` reports it |
| V1310 | minor | V1204 `review` profile | `review` lets php reach HTTPS on **any** address, not just SSO. With the guard on, the remaining callers are features a reviewer must trigger, such as repository downloads or H5P hub fetches | Optionally narrow `externalHttpsCidr` to SSO's address for the review window: `loginproxy.gov.bc.ca` resolves through BC's global load balancer to 142.34.229.4. If SSO fails over during CP3, the SSO check fails visibly, which is the safe direction |
| V1311 | minor | §0.11; V801 ("no Moodle code runs during the pause") | A php pod that starts during the nightly pause runs a Moodle CLI bootstrap (`configure-cache.php`). It opens a session as the `moodle` role, resetting the drain's 10-second quiet window, and may write `muc/config.php` and purge caches. It writes no database rows or `filedir` files, so pairing is unaffected | Skip the script when the backup's maintenance page is up (it has the `rp-backup-fence` marker), and note the exception to V801 |
| V1312 | minor | `config/nginx/default.conf.template` | The AJAX location matches any path under `/lib/ajax/` and `/webservice/`, not only PHP, and relies on PHP-FPM's default `.php`-only limit to refuse the rest (3 such files today). Also, nginx's own 502 and 504 still return the HTML page on AJAX and web-service paths (`error_page` is server-wide), and the mobile app's `/login/token.php` isn't in the AJAX set. §0.11 says every AJAX and web-service response passes through untouched | Require `\.php(/|$)` in the AJAX regex. Correct §0.11: upstream PHP responses pass untouched, but nginx's own 502 and 504 are the HTML page everywhere |
| V1313 | minor | Valkey configuration | The Redis store tells Moodle it guarantees data (`SUPPORTS_DATA_GUARANTEE`); Valkey runs `allkeys-lru` and would evict whole cache definitions (one hash each). Legacy runs `noeviction` and has never evicted (peak 37 MB). Purges use blocking `DEL` against a 1 s read timeout, so purging a large definition could time out concurrent requests | Keep 256 MB and `allkeys-lru` (safer than write errors), but count `evicted_keys` in every load and soak check. Add `lazyfree-lazy-user-del yes` so `DEL` frees in the background |
| V1314 | minor | §9 Performance acceptance, prerequisites | Moodle's generator plan needs `$CFG->tool_generator_users_password` in `config.php` (an image change, so it must go in before the next build). Synthetic users meet legacy dev's site-policy acceptance (`tool_policy`) on first login. The plan's login assertions must match the `bcgovpsa` theme, and the site must be out of maintenance. Time-bound quota applies only to a **pod-level** `activeDeadlineSeconds`, not the Job's | Add the config line, read from an environment variable that the chart sets only in dev. Pre-accept policies for the synthetic users. Check the assertions against the theme. Say "pod-level" in §9 |
| V1315 | minor | S16 access check | `access-diff.sh` sees cluster role bindings only. Tokens held outside the cluster were checked by hand. `bcgov/moodle-nginx` (public) holds dev, test and prod tokens as **repository** secrets, its environments have no required reviewers, and no branch is protected. Its writers can reach dev, and equally prod, so there's no widening for S16. psa-moodle's own `950003-dev` token sits behind its environment reviewer | Record this in S16. **Outside this plan:** tell the owner that legacy's repository lets every writer reach prod, with no reviewer and no protected branch. The owner already avoids pushing there (§0.8) |

### Checked and found sound
- **Concurrent cache setup:** Moodle's `config_writer::config_save` skips identical writes and writes under its own
  lock, so three php pods starting together can't corrupt `muc/config.php`.
- **V1202:** reproduced on Postgres 15.15 (§0.11). Moodle's lock-factory namespace for this database is 1289808297, and
  pgBackRest's own lock is a bigint key, so the backup's namespace collides with neither.
- **Build path:** `build-exact` builds the runtime stage from `Containerfile.php` (with the script), then cron and web
  from the build context (with the script, the snippet and the page).
- **The `review` verify step:** the cron Deployment renders with 0 replicas when cron is off, so the workflow's check
  works.
- **The moodledata backup** sets a pod-level deadline, so it counts against time-bound quota as §9 assumes.
- **Valkey's 256 MB** is about 7× legacy prod's peak use for sessions and caches together.

## Answers to the four §0.11 questions

1. **Does the implementation do what §0.11 says?** Mostly. The setup script, its idempotence and `--check`, the
   installer and start hooks, the workload change and the configuration files do what they claim. Three claims don't
   hold: "never stale" (V1301, V1302), "every failure shows the friendly page" (V1304) and "AJAX passes untouched"
   (V1312).
2. **Is a bounded interruption an acceptable basis for a single Valkey?** Yes, once V1301 and V1302 are fixed. The bound
   is then: a few in-flight failures, slower pages while Valkey is away, and no stale data. That is the owner's stated
   tolerance. Without those fixes, the cost of an outage isn't bounded in time, because stale data lasts until the
   affected users log out.
3. **Are the rehearsal states and load-test specification complete enough to run?** The storage and compute states are.
   The load test isn't: its path (V1305), comparison (V1306) and prerequisites (V1314) need deciding first. Without
   V1303, the 1,500-user run would mostly measure container kills.
4. **What else is needed before Pass B?** V1301–V1303 in code; V1309, V1311, V1312 and V1313, which are cheap enough to
   ride along; and the corrected claims and privacy note (V1304, V1307). Then a fresh `build-exact`.

## Recommended order
1. Code: V1301, V1302, V1303, V1309, V1311, V1312, V1313 and V1314's configuration line, all tested locally as v1.3 was.
2. Docs: correct the claims; S16's deletion step, residues and storage class; the H1 session step; the load-test path,
   comparison and prerequisites.
3. Send the corrected privacy note.
4. `build-exact`, uninstall Pass A, then Pass B, by the owner's approval at each step.
