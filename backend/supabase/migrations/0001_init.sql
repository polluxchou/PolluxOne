-- Pollux One — initial schema
--
-- Domain model mirrors ios/Pollux One/Domain: Script > ScriptSection >
-- Paragraph > Sentence, plus RecordingSession/ReadingSession/VoiceCommand.
-- Everything is scoped to auth.uid() via RLS — a user only ever sees their
-- own scripts and sessions. iOS and Web both read/write through this schema
-- directly for V1; nothing here assumes Supabase specifically beyond
-- auth.uid()/auth.users, so a future self-hosted API can reimplement the
-- same tables without changing the client-side BackendClient contracts.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Profiles (one row per auth.users, created on signup by the trigger below)
-- ---------------------------------------------------------------------------
create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  display_name text,
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

create policy "profiles are self-readable" on profiles
  for select using (auth.uid() = id);

create policy "profiles are self-updatable" on profiles
  for update using (auth.uid() = id);

create function handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();

-- ---------------------------------------------------------------------------
-- Devices (iOS clients that have synced scripts)
-- ---------------------------------------------------------------------------
create table devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  model text not null,
  last_seen_at timestamptz not null default now()
);

alter table devices enable row level security;

create policy "devices are owner-scoped" on devices
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Scripts and their content tree
-- ---------------------------------------------------------------------------
create table scripts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null default 'Untitled script',
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table scripts enable row level security;

create policy "scripts are owner-scoped" on scripts
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table script_sections (
  id uuid primary key default gen_random_uuid(),
  script_id uuid not null references scripts (id) on delete cascade,
  title text,
  sort_order integer not null default 0
);

alter table script_sections enable row level security;

create policy "script_sections follow parent script" on script_sections
  for all using (
    exists (select 1 from scripts s where s.id = script_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from scripts s where s.id = script_id and s.user_id = auth.uid())
  );

create table paragraphs (
  id uuid primary key default gen_random_uuid(),
  section_id uuid not null references script_sections (id) on delete cascade,
  sort_order integer not null default 0
);

alter table paragraphs enable row level security;

create policy "paragraphs follow parent script" on paragraphs
  for all using (
    exists (
      select 1 from script_sections sec
      join scripts s on s.id = sec.script_id
      where sec.id = section_id and s.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from script_sections sec
      join scripts s on s.id = sec.script_id
      where sec.id = section_id and s.user_id = auth.uid()
    )
  );

create table sentences (
  id uuid primary key default gen_random_uuid(),
  paragraph_id uuid not null references paragraphs (id) on delete cascade,
  sort_order integer not null default 0,
  text text not null default ''
);

alter table sentences enable row level security;

create policy "sentences follow parent script" on sentences
  for all using (
    exists (
      select 1 from paragraphs p
      join script_sections sec on sec.id = p.section_id
      join scripts s on s.id = sec.script_id
      where p.id = paragraph_id and s.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from paragraphs p
      join script_sections sec on sec.id = p.section_id
      join scripts s on s.id = sec.script_id
      where p.id = paragraph_id and s.user_id = auth.uid()
    )
  );

-- Bumps scripts.version and updated_at whenever a section is added, renamed,
-- reordered, or removed, so an iOS RecordingSession that froze a version can
-- detect a stale copy. Only wired to script_sections (see trigger below);
-- paragraph/sentence edits happen through the section they belong to.
create function touch_script_version()
returns trigger
language plpgsql
as $$
begin
  update scripts
    set version = version + 1, updated_at = now()
    where id = coalesce(new.script_id, old.script_id);
  return coalesce(new, old);
end;
$$;

create trigger sections_touch_script
  after insert or update or delete on script_sections
  for each row execute procedure touch_script_version();

-- ---------------------------------------------------------------------------
-- Recording / reading sessions
-- ---------------------------------------------------------------------------
create table recording_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  device_id uuid references devices (id) on delete set null,
  script_id uuid not null references scripts (id) on delete cascade,
  script_version integer not null,
  camera_configuration jsonb not null default '{}'::jsonb,
  local_video_filename text,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

alter table recording_sessions enable row level security;

create policy "recording_sessions are owner-scoped" on recording_sessions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table reading_sessions (
  id uuid primary key default gen_random_uuid(),
  recording_session_id uuid not null references recording_sessions (id) on delete cascade,
  current_position jsonb,
  completed_sentences integer not null default 0,
  total_sentences integer not null default 0,
  fraction_complete real not null default 0,
  is_paused boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table reading_sessions enable row level security;

create policy "reading_sessions follow parent recording session" on reading_sessions
  for all using (
    exists (
      select 1 from recording_sessions rs
      where rs.id = recording_session_id and rs.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from recording_sessions rs
      where rs.id = recording_session_id and rs.user_id = auth.uid()
    )
  );

-- Last-known reading progress per script, independent of any single take —
-- what ScriptSyncService.reportReadingProgress writes and the Web console's
-- script list can show ("42% read").
create table script_reading_progress (
  script_id uuid primary key references scripts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  completed_sentences integer not null default 0,
  total_sentences integer not null default 0,
  fraction_complete real not null default 0,
  updated_at timestamptz not null default now()
);

alter table script_reading_progress enable row level security;

create policy "script_reading_progress is owner-scoped" on script_reading_progress
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Voice commands (Safe Word -> Voice Command Engine audit trail)
-- ---------------------------------------------------------------------------
create table voice_commands (
  id uuid primary key default gen_random_uuid(),
  recording_session_id uuid not null references recording_sessions (id) on delete cascade,
  kind text not null,
  payload jsonb not null default '{}'::jsonb,
  transcript text not null,
  state text not null default 'proposed',
  recognized_at timestamptz not null default now()
);

alter table voice_commands enable row level security;

create policy "voice_commands follow parent recording session" on voice_commands
  for all using (
    exists (
      select 1 from recording_sessions rs
      where rs.id = recording_session_id and rs.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from recording_sessions rs
      where rs.id = recording_session_id and rs.user_id = auth.uid()
    )
  );
