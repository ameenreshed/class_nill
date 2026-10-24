# LPU Scheduler

Real-time room scheduling for Lovely Professional University. Shows why each room is free or booked — not just whether it's free.

## The problem it solves

The existing timetable view shows a room as "free" if no regular class is scheduled. But that room may already be:
- Booked by another faculty for a **makeup class**
- Reserved for an **exam**, **event**, or **maintenance**

Faculty then book the room, arrive, and find it occupied. LPU Scheduler fixes this by showing **why** each cell is what it is:

| Cell | Meaning |
|---|---|
| 🟢 Free | No booking of any kind — truly available |
| 🔵 Class | Regular class scheduled in the timetable |
| 🟠 Makeup | Someone has booked it for a makeup class |
| 🔴 Exam / Event / Maint | Reserved for something else |

## Files

```
index.html              Role router
login.html              ID + password only
reset-password.html     Self-service reset
student.html            ⭐ Free rooms grid (THE FIX)
faculty.html            Faculty dashboard
faculty-makeup.html     3-step makeup class booking
profile.html            Account + security
admin.html              Admin dashboard
admin-add.html          Quick offline room entry
admin-rooms.html        Room management
admin-users.html        User admin
admin-bookings.html     Booking approval
admin-settings.html     Buildings / types / slots
css/style.css           Design system
js/config.js            Supabase credentials ← EDIT THIS
js/core.js              Shared utilities
supabase/schema.sql     Complete DB schema
supabase/test-users.sql Test accounts
manifest.json           PWA manifest
sw.js                   Service worker (offline)
icons/icon.svg          App icon
vercel.json             Security headers
```

## Setup (10 minutes)

### 1. Create Supabase project
https://supabase.com → New project

### 2. Run schema
SQL editor → paste `supabase/schema.sql` → Run

### 3. Run test users
SQL editor → paste `supabase/test-users.sql` → Run

### 4. Enable Email auth
Authentication → Providers → **Email** → toggle on
**Confirm email** → turn OFF for testing

### 5. Configure URLs
Authentication → URL Configuration:
- **Site URL**: `http://localhost:3000`
- **Redirect URLs**: add `http://localhost:3000/reset-password.html`

### 6. Set credentials
Edit `js/config.js`:
```js
export const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJ...';
```
(from Supabase → Settings → API)

### 7. Run
```bash
cd path/to/project
python -m http.server 3000
```
Open http://localhost:3000/login.html

## Test accounts

| Role | Email | Password |
|---|---|---|
| Admin | admin@lpu.test | admin123 |
| Faculty | faculty@lpu.test | faculty123 |
| Student | student@lpu.test | student123 |

## Deploy to production

### Vercel
1. Push to GitHub
2. vercel.com/new → import repo → Deploy
3. Settings → Domains → add your subdomain
4. Update Supabase Site URL + Redirect URLs to the live domain
5. Update `js/config.js` if you push new credentials

### Supabase redirect URLs (required for login to work)
After deploying, add to **Authentication → URL Configuration**:
- Site URL: `https://your-domain.com`
- Redirect URLs: `https://your-domain.com/reset-password.html`

## Demo story for sir

1. **Open `student.html`** — this is the page that fixes the makeup-class problem
2. Point at the **blue "What's new"** banner at the top
3. Point at the **legend** — four cell types
4. Point at a **Makeup** cell (orange) — *"This room looks free in the old timetable, but a faculty already booked it. Old system says FREE. New system says MAKEUP."*
5. **Click any cell** — modal opens with the full day schedule for that room
6. **Change the date** — same view for any day
7. **Compare to current system** — that's the whole pitch

## Roles

- **student** → `/student.html` — free rooms grid
- **faculty** → `/faculty.html`, `/faculty-makeup.html` — book makeup classes
- **admin** → all `admin-*.html` — manage everything

## Security

- Row-level security on every table (enforced by Postgres, not JS)
- Sessions expire after 30 min of inactivity
- Password changes sign out all other devices
- Activity log captures every room, booking, and profile change
- Security headers via `vercel.json` (CSP, HSTS, X-Frame-Options, etc.)