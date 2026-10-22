# Family application

A lightweight shared family calendar prototype.

## Local preview

Serve this folder over localhost and open `index.html` in a browser. The app uses Supabase for its shared calendar and keeps its share link in the browser's local storage.

## Supabase setup

Run `supabase_schema.sql` and `supabase_shared_calendar.sql` in the Supabase SQL editor for a new project. The app uses the Supabase publishable key in `index.html`; never put a Supabase secret or service-role key in browser code.

## Project files

- `index.html` — calendar interface and client-side behavior
- `supabase_schema.sql` — initial database schema
- `supabase_shared_calendar.sql` — shared-link database functions and policies
- `outputs/family-calendar-share.svg` — calendar preview artwork
