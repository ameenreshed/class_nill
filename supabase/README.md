# amnrd.scheduler — Phase 1 prototype

Static HTML/CSS/JS + Supabase. No build step, no Node needed at runtime.

## Local dev

```bash
python3 -m http.server 3000
```

Open http://localhost:3000 — **do NOT open via file://** (ES modules won't load).

## Setup (5 min)

1. Create project at https://supabase.com
2. **SQL editor** → paste `supabase/schema.sql` → Run
3. **Authentication → Providers**:
   - Enable **Email** (magic link, no password)
   - Enable **GitHub** (create OAuth app at github.com → Settings → Developer settings;
     callback URL: `https://<project>.supabase.co/auth/v1/callback`)
4. **Authentication → URL Configuration**:
   - Site URL: `http://localhost:3000`
   - Redirect URLs: `http://localhost:3000/index.html`
5. Edit `js/config.js` with your project URL + anon key (from Settings → API)
6. `python3 -m http.server 3000` → open http://localhost:3000 → sign in
7. Promote yourself to admin in Supabase SQL editor:
   ```sql
   update profiles set role = 'admin' where email = 'you@example.com';
   ```
8. Refresh → you'll land on `admin.html` → add rooms → check `student.html`

## Deploy to scheduler.amnrd.com

1. Push folder to GitHub repo
2. vercel.com/new → import → Deploy (static site, no build config)
3. Vercel → Settings → Domains → add `scheduler.amnrd.com`
4. Registrar DNS → CNAME `scheduler` → `cname.vercel-dns.com`
5. Update Supabase Site URL to `https://scheduler.amnrd.com`
6. Update redirect URLs to `https://scheduler.amnrd.com/index.html`
7. Update GitHub OAuth callback in Supabase dashboard → Providers → GitHub
8. Test login on live URL

## Roles

- **student** → `student.html` (vacancy grid)
- **faculty** → `faculty.html`, `faculty-makeup.html`
- **admin** → `admin*.html`

## Files

```
index.html            role router
login.html            OAuth + magic link
student.html          vacancy grid
faculty.html          faculty dashboard
faculty-makeup.html   makeup booking with conflict check
admin.html            dashboard with stats
admin-rooms.html      room CRUD
admin-users.html      role management
admin-bookings.html   approve/reject
css/style.css         full stylesheet
js/config.js          Supabase credentials
js/core.js            auth, nav, helpers
supabase/schema.sql   DB schema + RLS + seed
```