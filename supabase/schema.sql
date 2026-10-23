create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  full_name text,
  role text not null default 'student' check (role in ('admin','faculty','student')),
  department text,
  created_at timestamptz default now()
);

create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email), 'student')
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

create table if not exists rooms (
  room_id text primary key,
  display_name text not null,
  building text not null,
  floor int not null check (floor between 1 and 10),
  floor_digit text not null,
  room_number text not null,
  suffix text default '',
  type text not null check (type in ('lecture','lab','seminar','library','other')),
  capacity int,
  bookable boolean default true,
  weekend_open boolean default false,
  facilities text[] default '{}',
  notes text,
  created_at timestamptz default now()
);

create index if not exists rooms_lookup on rooms (building, floor, bookable);

create table if not exists time_slots (
  slot_id text primary key,
  start_time time not null,
  end_time time not null,
  label text
);

insert into time_slots (slot_id, start_time, end_time, label) values
  ('P1','09:00','09:50','1st period'),
  ('P2','09:50','10:40','2nd period'),
  ('P3','10:50','11:40','3rd period'),
  ('P4','11:40','12:30','4th period'),
  ('P5','13:30','14:20','5th period'),
  ('P6','14:20','15:10','6th period'),
  ('P7','15:10','16:00','7th period')
on conflict (slot_id) do nothing;

create table if not exists sections (
  section_id text primary key,
  name text not null,
  strength int default 60,
  department text
);

create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  room_id text not null references rooms(room_id) on delete cascade,
  book_date date not null,
  slot_id text not null references time_slots(slot_id),
  type text not null check (type in ('regular','makeup','exam','event','maintenance')),
  section_id text references sections(section_id),
  faculty_id uuid references profiles(id) on delete set null,
  course_code text,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','cancelled')),
  reason text,
  created_by uuid references profiles(id) on delete set null,
  approved_by uuid references profiles(id) on delete set null,
  created_at timestamptz default now()
);

create unique index if not exists bookings_no_overlap
  on bookings (room_id, book_date, slot_id)
  where status in ('pending','approved');

create index if not exists bookings_date_slot on bookings (book_date, slot_id, status);
create index if not exists bookings_faculty on bookings (faculty_id, book_date);
create index if not exists bookings_section on bookings (section_id, book_date);

alter table profiles enable row level security;
alter table rooms enable row level security;
alter table sections enable row level security;
alter table bookings enable row level security;
alter table time_slots enable row level security;

create or replace function my_role() returns text
language sql stable security definer as $$
  select coalesce((select role from profiles where id = auth.uid()), 'student');
$$;

drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select
  using (id = auth.uid() or my_role() = 'admin');

drop policy if exists "profiles admin write" on profiles;
create policy "profiles admin write" on profiles for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "rooms read" on rooms;
create policy "rooms read" on rooms for select using (auth.role() = 'authenticated');

drop policy if exists "rooms admin write" on rooms;
create policy "rooms admin write" on rooms for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "slots read" on time_slots;
create policy "slots read" on time_slots for select using (true);

drop policy if exists "sections read" on sections;
create policy "sections read" on sections for select using (auth.role() = 'authenticated');

drop policy if exists "sections admin write" on sections;
create policy "sections admin write" on sections for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "bookings read" on bookings;
create policy "bookings read" on bookings for select using (
  status = 'approved'
  or my_role() = 'admin'
  or faculty_id = auth.uid()
  or created_by = auth.uid()
);

drop policy if exists "bookings insert" on bookings;
create policy "bookings insert" on bookings for insert with check (
  my_role() in ('faculty','admin') and created_by = auth.uid()
);

drop policy if exists "bookings update" on bookings;
create policy "bookings update" on bookings for update using (
  my_role() = 'admin' or (faculty_id = auth.uid() and status = 'pending')
);

drop policy if exists "bookings delete" on bookings;
create policy "bookings delete" on bookings for delete using (
  my_role() = 'admin' or (created_by = auth.uid() and status = 'pending')
);

insert into rooms (room_id,display_name,building,floor,floor_digit,room_number,suffix,type,capacity,bookable,weekend_open,facilities) values
  ('27-107', '27-107',   '27',1,'1','07','', 'lecture',60,true, false,'{projector,fan}'),
  ('27-107A','27-107 A', '27',1,'1','07','A','lecture',60,true, false,'{projector,fan}'),
  ('27-108', '27-108',   '27',1,'1','08','', 'lab',    30,true, true, '{computers,ac}'),
  ('27-207A','27-207 A', '27',2,'2','07','A','lecture',60,true, false,'{projector,fan}'),
  ('27-208', '27-208',   '27',2,'2','08','', 'lab',    30,true, false,'{computers,ac}')
on conflict (room_id) do nothing;