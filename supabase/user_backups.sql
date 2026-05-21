-- Create per-user cloud backup table for CourseHub.
create table if not exists public.user_backups (
  user_id uuid primary key references auth.users (id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create or replace function public.set_user_backups_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists trg_user_backups_updated_at on public.user_backups;
create trigger trg_user_backups_updated_at
before update on public.user_backups
for each row
execute function public.set_user_backups_updated_at();

alter table public.user_backups enable row level security;

drop policy if exists "Users can view own backup" on public.user_backups;
create policy "Users can view own backup"
on public.user_backups
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users can insert own backup" on public.user_backups;
create policy "Users can insert own backup"
on public.user_backups
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Users can update own backup" on public.user_backups;
create policy "Users can update own backup"
on public.user_backups
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "Users can delete own backup" on public.user_backups;
create policy "Users can delete own backup"
on public.user_backups
for delete
to authenticated
using (auth.uid() = user_id);

grant select, insert, update, delete on table public.user_backups to authenticated;
