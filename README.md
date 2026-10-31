# LPU Scheduler

Centralized classroom scheduling for Lovely Professional University.
Admin + faculty roles only. Live free-rooms grid. Makeup-from-leave. CSV import.

## Prerequisites

- A Supabase project (free tier works)
- Node.js (only if running locally with a dev server)
- A Cloudflare account (for Turnstile bot protection)

## Setup — 5 minutes

### 1. Supabase

1. Create project at https://supabase.com
2. **SQL Editor** → paste `supabase/PRODUCTION-CLEAN.sql` → edit admin credentials (line ~380) → Run
3. **Authentication → Providers → Email** → enabled (default ON)
4. **Authentication → URL Configuration**:
   - Site URL: `https://your-domain.com`
   - Redirect URLs: `https://your-domain.com/reset-password.html`
5. **Project Settings → API** → copy `Project URL` and `anon public` key

### 2. Cloudflare Turnstile

1. Visit https://dash.cloudflare.com → Turnstile → Add site
2. Domain: `your-domain.com`
3. Widget mode: **Managed**
4. Copy **Site Key** → replace in `login.html`:
   ```js
   const TURNSTILE_SITE_KEY = '0x4AAAAAAA...';