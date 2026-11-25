# LPU Scheduler

Centralized classroom scheduling for Lovely Professional University.
Admin + faculty roles. Live free-rooms grid, makeup-from-leave, CSV import, assignment collection.

## Folder structure

```
/
├── index.html            Public landing page (what the app is, Sign in button)
├── manifest.json         PWA manifest
├── sw.js                 Service worker (must stay at root)
├── vercel.json           Security headers + redirects from the old flat URLs
│
├── auth/
│   ├── login.html        Sign in (Turnstile + Supabase auth)
│   └── redirect.html     Role router: checks session/profile, sends to /admin/, /faculty/ or login
│
├── admin/                Admin only
│   ├── index.html        Dashboard
│   └── assignments, batches, bookings, calendar, faculty, import, rooms, settings, slots, students, timetable .html
│
├── faculty/              Faculty only
│   ├── index.html        Dashboard
│   └── assignments.html
│
├── student/              Student only
│   └── index.html        My assignments: batch deadlines, submission status, files
│
├── shared/               Any signed-in user (+ public credits)
│   ├── free-rooms.html
│   ├── profile.html
│   └── credits.html
│
├── submit/index.html     Public student upload page (opened via share link ?token=...)
│
├── assets/
│   ├── css/              style.css, admin.css, mobile-app.css
│   ├── js/               config.js (Supabase keys), core.js, banner.js, pwa.js
│   └── icons/
│
└── supabase/             schema.sql, assignments.sql, admin-assignment.sql
```

## Roles

- **admin**: everything, including Batches (pause/resume, rename, move students, create student logins).
- **faculty**: own assignments, bookings, timetable view.
- **student**: `/student/` dashboard showing assignments for their batch. Students sign in with their student ID (same login page as staff). An admin creates their login from `/admin/batches.html` with a temporary password. They must set their own password on first sign-in.

## User flow

`/` landing → **Sign in** → `/auth/login.html` → `/auth/redirect.html` logic →
first login: `/shared/profile.html?first=1` (set password) → `/admin/` or `/faculty/`.

All internal links are root-absolute (`/admin/rooms.html`), so serve the folder from the web root
(Vercel, or locally `npx serve .` / `python3 -m http.server`). Opening files via `file://` will not work.

## Setup

1. **Supabase**: create a project, run `supabase/schema.sql`, then `assignments.sql`, `admin-assignment.sql`, and finally `student-batches.sql`.
   Authentication → Email provider enabled. Set Site URL / Redirect URLs to your domain.
2. **Config**: put your Project URL and anon key in `assets/js/config.js`.
3. **Cloudflare Turnstile**: add your site key as `TURNSTILE_SITE_KEY` in `auth/login.html`.
4. **Deploy** to Vercel with this folder as the project root.
