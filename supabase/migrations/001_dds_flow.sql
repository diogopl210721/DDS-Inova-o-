create extension if not exists pgcrypto;
create extension if not exists citext;
create extension if not exists pg_trgm;

create schema if not exists dds_flow;
grant usage on schema dds_flow to authenticated, service_role;

do $$ begin create type dds_flow.demand_status as enum ('new','in_progress','waiting_client','waiting_internal','need_follow_up','completed'); exception when duplicate_object then null; end $$;
do $$ begin create type dds_flow.demand_priority as enum ('low','medium','high','urgent'); exception when duplicate_object then null; end $$;
do $$ begin create type dds_flow.dependency_type as enum ('self','client','commercial','finance','logistics','contracts','internal_contact','other'); exception when duplicate_object then null; end $$;

create table if not exists dds_flow.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default 'Usuário', timezone text not null default 'America/Sao_Paulo', locale text not null default 'pt-BR',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists dds_flow.user_settings (
  user_id uuid primary key references dds_flow.profiles(id) on delete cascade,
  day_start time not null default '08:00', day_end time not null default '17:00', contract_auto_demand boolean not null default false,
  daily_carryover_enabled boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists dds_flow.clients (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
  code text, trade_name text not null, legal_name text, contact_name text, phone text, email citext, delivery_address text,
  tank_capacity numeric(14,3) check(tank_capacity>=0), tank_capacity_unit text not null default 'kg',
  avg_consumption_6m numeric(14,3) check(avg_consumption_6m>=0), consumption_unit text not null default 'kg', notes text,
  is_active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), archived_at timestamptz
);
create unique index if not exists clients_user_code_uidx on dds_flow.clients(user_id,lower(code)) where code is not null;
create index if not exists clients_user_name_idx on dds_flow.clients(user_id,lower(trade_name));
create index if not exists clients_name_trgm_idx on dds_flow.clients using gin(trade_name gin_trgm_ops);

create table if not exists dds_flow.internal_contacts (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
  name text not null, department text, job_title text, email citext, phone text, whatsapp text, notes text, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists contacts_user_name_idx on dds_flow.internal_contacts(user_id,lower(name));

create table if not exists dds_flow.contracts (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
  client_id uuid not null references dds_flow.clients(id) on delete cascade, contract_number text, start_date date not null, end_date date not null,
  is_primary boolean not null default true, status text not null default 'active' check(status in ('draft','active','expired','renewed','cancelled')),
  notes text, renewed_from_id uuid references dds_flow.contracts(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint contract_dates check(end_date>=start_date)
);
create unique index if not exists contracts_primary_active_uidx on dds_flow.contracts(client_id) where is_primary and status='active';
create index if not exists contracts_user_end_idx on dds_flow.contracts(user_id,end_date) where status='active';

create table if not exists dds_flow.demands (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
  client_id uuid references dds_flow.clients(id) on delete set null, title text not null, description text, external_code text, category text,
  status dds_flow.demand_status not null default 'new', priority dds_flow.demand_priority not null default 'medium', dependency dds_flow.dependency_type not null default 'self',
  internal_contact_id uuid references dds_flow.internal_contacts(id) on delete set null, next_action text, next_action_at timestamptz,
  scheduled_for date not null default current_date, origin text not null default 'manual' check(origin in ('manual','ai','contract_alert','carryover')),
  source_text text, started_at timestamptz, completed_at timestamptz, last_activity_at timestamptz not null default now(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), archived_at timestamptz,
  constraint demand_completion check((status='completed' and completed_at is not null) or status<>'completed'),
  constraint demand_internal_contact check(dependency<>'internal_contact' or internal_contact_id is not null)
);
create index if not exists demands_user_status_date_idx on dds_flow.demands(user_id,status,next_action_at);
create index if not exists demands_client_activity_idx on dds_flow.demands(client_id,last_activity_at desc);
create index if not exists demands_title_trgm_idx on dds_flow.demands using gin(title gin_trgm_ops);

create table if not exists dds_flow.follow_ups (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
 demand_id uuid not null references dds_flow.demands(id) on delete cascade, internal_contact_id uuid references dds_flow.internal_contacts(id) on delete set null,
 due_at timestamptz not null, action text not null, completed_at timestamptz, result text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists followups_user_due_idx on dds_flow.follow_ups(user_id,due_at) where completed_at is null;

create table if not exists dds_flow.demand_events (
 id bigint generated always as identity primary key, user_id uuid not null references dds_flow.profiles(id) on delete cascade,
 demand_id uuid not null references dds_flow.demands(id) on delete cascade, actor_user_id uuid references dds_flow.profiles(id) on delete set null,
 event_type text not null, summary text not null, before_data jsonb, after_data jsonb, metadata jsonb not null default '{}', created_at timestamptz not null default now()
);
create index if not exists events_demand_created_idx on dds_flow.demand_events(demand_id,created_at desc);

create table if not exists dds_flow.diary_days (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
 day date not null, status text not null default 'open' check(status in ('open','closed','reopened')), opened_at timestamptz not null default now(), closed_at timestamptz,
 ai_summary text, closing_snapshot jsonb, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(user_id,day)
);
create table if not exists dds_flow.diary_entries (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
 diary_day_id uuid not null references dds_flow.diary_days(id) on delete cascade, demand_id uuid not null references dds_flow.demands(id) on delete cascade,
 carried_from_entry_id uuid references dds_flow.diary_entries(id) on delete set null, appeared_at timestamptz not null default now(), resolved_on_day boolean not null default false,
 day_snapshot jsonb not null default '{}', unique(diary_day_id,demand_id)
);
create table if not exists dds_flow.attachments (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
 client_id uuid references dds_flow.clients(id) on delete cascade, demand_id uuid references dds_flow.demands(id) on delete cascade,
 bucket_id text not null default 'dds-flow-private', object_path text not null, original_name text not null, mime_type text not null, size_bytes bigint not null check(size_bytes>0),
 kind text not null default 'other', sha256 text, created_at timestamptz not null default now(), unique(bucket_id,object_path), check(client_id is not null or demand_id is not null)
);
create table if not exists dds_flow.communications (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references dds_flow.profiles(id) on delete cascade,
 demand_id uuid references dds_flow.demands(id) on delete set null, client_id uuid references dds_flow.clients(id) on delete set null,
 internal_contact_id uuid references dds_flow.internal_contacts(id) on delete set null, channel text not null check(channel in ('email','whatsapp')),
 recipient text not null, subject text, body text not null, tone text, state text not null default 'drafted' check(state in ('drafted','opened','discarded')),
 opened_at timestamptz, created_at timestamptz not null default now()
);

create or replace function dds_flow.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into dds_flow.profiles(id,full_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1))) on conflict do nothing;
 insert into dds_flow.user_settings(user_id) values(new.id) on conflict do nothing;
 return new;
end $$;
revoke all on function dds_flow.handle_new_user() from public, anon, authenticated;
drop trigger if exists on_auth_user_created_dds_flow on auth.users;
create trigger on_auth_user_created_dds_flow after insert on auth.users for each row execute procedure dds_flow.handle_new_user();
insert into dds_flow.profiles(id,full_name)
select id,coalesce(raw_user_meta_data->>'full_name',split_part(email,'@',1)) from auth.users
on conflict(id) do nothing;
insert into dds_flow.user_settings(user_id) select id from dds_flow.profiles on conflict(user_id) do nothing;

create or replace function dds_flow.audit_demand() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='INSERT' then
  insert into dds_flow.demand_events(user_id,demand_id,actor_user_id,event_type,summary,after_data) values(new.user_id,new.id,auth.uid(),'created','Demanda criada',to_jsonb(new));
 elsif tg_op='UPDATE' then
  insert into dds_flow.demand_events(user_id,demand_id,actor_user_id,event_type,summary,before_data,after_data)
  values(new.user_id,new.id,auth.uid(),case when new.status='completed' and old.status<>'completed' then 'completed' when new.status<>old.status then 'status_changed' else 'updated' end,'Demanda atualizada',to_jsonb(old),to_jsonb(new));
 end if; return new;
end $$;
revoke all on function dds_flow.audit_demand() from public, anon;
drop trigger if exists demand_audit on dds_flow.demands;
create trigger demand_audit after insert or update on dds_flow.demands for each row execute procedure dds_flow.audit_demand();

create or replace function dds_flow.block_event_mutation() returns trigger language plpgsql as $$ begin raise exception 'Timeline é imutável'; end $$;
revoke all on function dds_flow.block_event_mutation() from public, anon;
drop trigger if exists demand_events_immutable on dds_flow.demand_events;
create trigger demand_events_immutable before update or delete on dds_flow.demand_events for each row execute procedure dds_flow.block_event_mutation();

do $$ declare t text; begin
 foreach t in array array['profiles','user_settings','clients','internal_contacts','contracts','demands','follow_ups','demand_events','diary_days','diary_entries','attachments','communications'] loop
  execute format('alter table dds_flow.%I enable row level security',t);
  execute format('revoke all on table dds_flow.%I from anon, authenticated',t);
  execute format('grant select,insert,update,delete on table dds_flow.%I to authenticated',t);
 end loop;
end $$;
grant usage, select on all sequences in schema dds_flow to authenticated;

create policy profiles_select_own on dds_flow.profiles for select to authenticated using(id=(select auth.uid()));
create policy profiles_update_own on dds_flow.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));

do $$ declare t text; begin
 foreach t in array array['user_settings','clients','internal_contacts','contracts','demands','follow_ups','diary_days','diary_entries','attachments','communications'] loop
  execute format('create policy %I on dds_flow.%I for select to authenticated using(user_id=(select auth.uid()))',t||'_select_own',t);
  execute format('create policy %I on dds_flow.%I for insert to authenticated with check(user_id=(select auth.uid()))',t||'_insert_own',t);
  execute format('create policy %I on dds_flow.%I for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()))',t||'_update_own',t);
  execute format('create policy %I on dds_flow.%I for delete to authenticated using(user_id=(select auth.uid()))',t||'_delete_own',t);
 end loop;
end $$;
create policy events_select_own on dds_flow.demand_events for select to authenticated using(user_id=(select auth.uid()));
create policy events_insert_own on dds_flow.demand_events for insert to authenticated with check(user_id=(select auth.uid()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dds-flow-private','dds-flow-private',false,20971520,array['application/pdf','image/jpeg','image/png','image/webp','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/csv'])
on conflict(id) do update set public=false;
create policy dds_flow_storage_select_own on storage.objects for select to authenticated using(bucket_id='dds-flow-private' and (storage.foldername(name))[1]=(select auth.uid()::text));
create policy dds_flow_storage_insert_own on storage.objects for insert to authenticated with check(bucket_id='dds-flow-private' and (storage.foldername(name))[1]=(select auth.uid()::text));
create policy dds_flow_storage_delete_own on storage.objects for delete to authenticated using(bucket_id='dds-flow-private' and (storage.foldername(name))[1]=(select auth.uid()::text));
