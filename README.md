# Kastalia KMS

A Perl/Dancer2 + PostgreSQL knowledge-management system built on two
tables: **knots** (nodes — a name, rich-text content, and an arbitrary
`hstore` bag of attributes like `img_url`, `epoch`, `template`, `skin`...)
and **bounds** (typed, weighted edges between knots — `is_parent`,
`echoes`, `has_bookmark`, `created_by`, and others). A knot's `knot_name`
is a materialized path (`domain/Section/Subsection/Leaf`), so the same
graph naturally serves multiple distinct public domains, each one able to
render its own slice of the graph through its own look.

This one install can simultaneously be:
- a plain content/wiki-style site (the default `knot` template, or any of
  the ten ready-made "canonical" views — `console`, `treehouse`, `arena`,
  `samizdat`, `ledger`, `offgrid`, `voyage`, `atlas`, `network`,
  `greenhouse` — each a distinct look+traversal a domain can declare as
  its own via `domain_template` in config.yml),
- a slide-deck/course-overview system (`mainframe.tt`/`kolleg.tt` +
  `semester.tt`), including a live classroom-cast feature (teacher →
  student WebSocket sync of slide/fragment/audio state, see "Classroom
  cast" below),
- or a minimal link-tree page (`linktree.tt`).

## Repository layout

```
lib/Kastalia/
  Main.pm             routes, request hooks, the generic knot-dispatch
                       route (resolves a knot_id + template name and
                       renders it), rate limiting
  API.pm              /api/* JSON/AJAX endpoints
  Core.pm             addKnot/addBound/knotize, attach_attributes
                       (merges hstore attributes onto a row + derives
                       date/ae_epoch from `epoch`), content sanitization
  SelectorQueries.pm  the bulk of the read-only SQL (get_last, get_bounds,
                       get_zeitgeist, ...)
  TT.pm               Template Toolkit vmethods -- most of the graph
                       traversal (get_children, get_full_deck,
                       get_ancestor_chain, get_echoes, ...) lives here as
                       `knot_id.some_method` calls from inside templates
  User.pm             LDAP account creation / password reset
views/                one .tt file per template (see "Templates" above);
  modules/            shared partials (breadcrumbs, skin pickers, the
                       infinite-scroll script, etc.)
sql/kastalia          schema + seed data for a fresh database
bin/app.psgi          PSGI entry point
```

## Setting up a fresh install

```shellscript
# System packages
apt install postgresql postgresql-contrib nginx memcached cpanminus libdbd-pg-perl
# Runtime tools the app shells out to for specific features -- install
# whichever features you actually plan to use:
apt install ffmpeg          # /new_audio_knot/, /audio/<id>.mp3 (webm/ogg -> wav/mp3)
apt install opus-tools      # /new_audio_knot/, /speech_segment/ (opusenc)
apt install tesseract-ocr tesseract-ocr-deu  # /ocr_img/
apt install imagemagick     # /ocr_img/ (identify)
apt install wget curl       # /wiki/ (mirrors a Wikipedia article), /audio/<id>.ogg (fetches a remote ogg_url)

# Clone
git clone https://github.com/hromi/kastalia /var/www/kastalia-kms
cd /var/www/kastalia-kms

# Perl dependencies (see cpanfile for the full list)
cpanm --installdeps .

# Config -- copy the template and fill in real values. config.yml is
# gitignored on purpose: it holds real secrets (ldap_pass,
# CAST_TOKEN_SECRET) and must never be committed.
cp config_template.yml config.yml
$EDITOR config.yml

# Database
su postgres
createuser kastalia
createdb kastalia_db -O kastalia
psql kastalia_db < sql/kastalia
exit

# Service + reverse proxy (edit the paths/domain in these two files first
# -- they ship with placeholder paths)
cp kastalia.service /etc/systemd/system/
cp kastalia.nginx /etc/nginx/sites-available/
ln -s /etc/nginx/sites-available/kastalia.nginx /etc/nginx/sites-enabled/
certbot -d YOURDOMAIN

systemctl daemon-reload
systemctl enable --now kastalia
systemctl reload nginx

# If the site doesn't come up, check logs/error.log, or run the app
# directly to see why it's dying:
perl bin/app.psgi
```

### Classroom cast (optional)

`mainframe.tt`/`kolleg.tt`'s live teacher → student sync talks to a small
standalone WebSocket relay that is **not part of this repo**
(`teacher.py`, proxied at nginx's `/ws` location — see
`/var/www/wizzion2/teacher/` on the reference deployment). If you want
that feature:

1. Set `CAST_TOKEN_SECRET` in `config.yml` (`openssl rand -hex 32`).
2. Set the identical value as `teacher.py`'s own `CAST_TOKEN_SECRET`
   environment variable (its systemd unit's `Environment=` line).
3. `teacher.py` should bind `127.0.0.1` only, with nginx proxying `/ws` to
   it — never expose its port directly to the internet.

If you don't use this feature, just leave `CAST_TOKEN_SECRET` unset: the
cast routes fail closed (no one can start a cast), which is safe.

## Security notes

- **`config.yml` must stay out of git.** It holds `ldap_pass` and
  `CAST_TOKEN_SECRET` in plaintext. `.gitignore` already excludes it, but
  that only stops it being added *automatically* — an explicit
  `git add config.yml` (or `git add -A`) will still happily stage it, so
  double-check `git status` before committing if you ever touch it.
- **`account_admins`** (config.yml) is matched as an *exact* login name,
  pipe-separated (`root|alice|bob`) — not a substring and not a regex
  pattern you should get creative with.
- **Every route that shells out** (ffmpeg/opusenc/wget/curl/tesseract/
  identify) does so with `String::ShellQuote` around any value that isn't
  a compile-time literal. If you add a new one, quote it the same way —
  several of these were unauthenticated command injection until a 2026
  security audit fixed them (see git log).
- **`VOICEAUTH_SEED`** (optional, voice-login feature) must either be a
  real secret shared with the external voice-recognition service, or left
  entirely unset. It must never be an empty string you "meant to fill in
  later" — that was previously a full authentication bypass.
- This app has **no CSRF tokens**; the one mitigation in place is an
  Origin-header check on POST requests (`hook before` in `Main.pm`),
  which only helps because it's paired with the session cookie having
  `SameSite=Lax`. Don't remove either without replacing them with real
  per-form tokens.
- Template Toolkit output is **not auto-escaped** anywhere in this app.
  `knot_content` is sanitized at write time (`Core.pm`'s
  `sanitize_knot_content`, a blocklist, not a full HTML sanitizer) rather
  than at render time — if you add a new place that writes `knot_content`
  or a `*_url`-style attribute, route it through the existing sanitizer/
  `safe_url`/`safe_js_array` TT vmethods rather than assuming the template
  layer will escape it for you, because it won't.
