-- Metabolix v1.2 : script complet de la base.
-- À coller dans Supabase > SQL Editor (mode base de données, pas « Logs »), puis « Run ».
-- Il peut être relancé sans risque : il ne supprime aucune donnée.

-- ========== 0. Copie de secours (v1.2) ==========
-- Avant toute modification, on copie les tables existantes dans un schéma privé « backup »,
-- invisible pour les joueurs (il n'est pas exposé par l'API). Rien n'est supprimé.
create schema if not exists backup;
revoke all on schema backup from public;
do $$
declare t text;
begin
  foreach t in array array['scores','saves','weekly','pseudos','champions','reports'] loop
    if to_regclass('public.' || t) is not null and to_regclass('backup.' || t || '_avant_v12') is null then
      execute format('create table backup.%I as table public.%I', t || '_avant_v12', t);
    end if;
  end loop;
end $$;

-- ========== Outils ==========
create or replace function public.current_week() returns date
language sql stable as $$ select (date_trunc('week', now() at time zone 'Europe/Paris'))::date $$;

create or replace function public.sid_of(p_code text) returns text
language sql immutable as $$ select encode(substring(sha256(convert_to('sid:' || p_code, 'UTF8')) from 1 for 6), 'hex') $$;

-- ========== 1. Classement général ==========
create table if not exists public.scores (
  id uuid primary key references auth.users (id) on delete cascade,
  pseudo text not null default '' check (char_length(pseudo) <= 20),
  xp integer not null default 0 check (xp between 0 and 5000000),
  stars integer not null default 0 check (stars between 0 and 90),
  rank text not null default '' check (char_length(rank) <= 30),
  updated_at timestamptz not null default now()
);
alter table public.scores add column if not exists sid text not null default '' check (char_length(sid) <= 16);
alter table public.scores enable row level security;
drop policy if exists "classement lisible" on public.scores;
drop policy if exists "creer sa ligne" on public.scores;
drop policy if exists "modifier sa ligne" on public.scores;
create policy "classement lisible" on public.scores for select using (true);
create policy "creer sa ligne" on public.scores for insert to authenticated with check (auth.uid() = id);
create policy "modifier sa ligne" on public.scores for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
create index if not exists scores_xp_idx on public.scores (xp desc);

-- ========== 2. Signalements d'erreurs ==========
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  voie text not null default '' check (char_length(voie) <= 80),
  texte text not null check (char_length(texte) between 3 and 1000),
  user_id uuid default auth.uid()
);
alter table public.reports enable row level security;
drop policy if exists "envoyer un signalement" on public.reports;
create policy "envoyer un signalement" on public.reports for insert to authenticated with check (true);

-- ========== 3. Sauvegarde en ligne (code personnel) ==========
create table if not exists public.saves (
  code_hash text primary key,
  state jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.saves enable row level security;

create or replace function public.save_progress(p_code text, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare h text;
begin
  if p_code !~ '^MTBX-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}$' then raise exception 'code invalide'; end if;
  if pg_column_size(p_state) > 200000 then raise exception 'sauvegarde trop lourde'; end if;
  h := encode(sha256(convert_to(p_code, 'UTF8')), 'hex');
  insert into public.saves (code_hash, state, updated_at) values (h, p_state, now())
  on conflict (code_hash) do update set state = excluded.state, updated_at = now()
  where coalesce((public.saves.state->>'updatedAt')::bigint, 0) <= coalesce((excluded.state->>'updatedAt')::bigint, 0);
end $$;

create or replace function public.load_progress(p_code text)
returns jsonb language sql security definer set search_path = public stable as $$
  select state from public.saves where code_hash = encode(sha256(convert_to(p_code, 'UTF8')), 'hex');
$$;

-- ========== 4. Pseudos uniques (v1.1) ==========
create table if not exists public.pseudos (
  pseudo_key text primary key,          -- pseudo en minuscules
  owner text not null,                  -- joueur (dérivé de son code de sauvegarde)
  pseudo text not null,
  updated_at timestamptz not null default now()
);
alter table public.pseudos enable row level security;  -- aucune politique : accès par fonctions seulement

create or replace function public.claim_pseudo(p_code text, p_pseudo text)
returns text language plpgsql security definer set search_path = public as $$
declare o text; p text; k text; cur text;
begin
  if p_code !~ '^MTBX-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}$' then return 'code'; end if;
  p := btrim(regexp_replace(coalesce(p_pseudo, ''), '\s+', ' ', 'g'));
  if char_length(p) < 2 or char_length(p) > 20 then return 'longueur'; end if;
  o := sid_of(p_code); k := lower(p);
  select owner into cur from pseudos where pseudo_key = k;
  if cur is not null and cur <> o then return 'pris'; end if;
  delete from pseudos where owner = o and pseudo_key <> k;
  insert into pseudos (pseudo_key, owner, pseudo) values (k, o, p)
  on conflict (pseudo_key) do update set pseudo = excluded.pseudo, updated_at = now() where pseudos.owner = excluded.owner;
  if (select owner from pseudos where pseudo_key = k) <> o then return 'pris'; end if;
  update scores set pseudo = p where sid = o;
  update weekly set pseudo = p where sid = o and week = current_week();
  return 'ok';
end $$;

-- Un pseudo non validé (ou celui de quelqu'un d'autre) n'est jamais affiché
create or replace function public.check_pseudo() returns trigger
language plpgsql security definer set search_path = public as $$
declare canon text;
begin
  if coalesce(new.pseudo, '') <> '' then
    select pseudo into canon from pseudos where pseudo_key = lower(btrim(new.pseudo)) and owner = new.sid and new.sid <> '';
    new.pseudo := coalesce(canon, '');
  end if;
  return new;
end $$;

-- ========== 5. Classement de la semaine (v1.1) ==========
create table if not exists public.weekly (
  week date not null,
  uid uuid not null references auth.users (id) on delete cascade,
  sid text not null default '' check (char_length(sid) <= 16),
  pseudo text not null default '' check (char_length(pseudo) <= 20),
  xp integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (week, uid)
);
alter table public.weekly enable row level security;
drop policy if exists "hebdo lisible" on public.weekly;
drop policy if exists "hebdo creer sa ligne" on public.weekly;
drop policy if exists "hebdo modifier sa ligne" on public.weekly;
create policy "hebdo lisible" on public.weekly for select using (true);
create policy "hebdo creer sa ligne" on public.weekly for insert to authenticated with check (auth.uid() = uid);
create policy "hebdo modifier sa ligne" on public.weekly for update to authenticated using (auth.uid() = uid) with check (auth.uid() = uid);
create index if not exists weekly_week_xp_idx on public.weekly (week, xp desc);

-- Garde-fous : seulement la semaine en cours, pas de gains absurdes
create or replace function public.check_weekly() returns trigger
language plpgsql as $$
begin
  if new.week <> current_week() then raise exception 'semaine terminée'; end if;
  if new.xp < 0 or new.xp > 1000000 then raise exception 'xp invalide'; end if;
  if tg_op = 'INSERT' and new.xp > 150000 then raise exception 'xp invalide'; end if;
  if tg_op = 'UPDATE' and new.xp - old.xp > 80000 then raise exception 'gain trop rapide'; end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists scores_pseudo on public.scores;
create trigger scores_pseudo before insert or update on public.scores for each row execute function public.check_pseudo();
drop trigger if exists weekly_pseudo on public.weekly;
create trigger weekly_pseudo before insert or update on public.weekly for each row execute function public.check_pseudo();
drop trigger if exists weekly_guard on public.weekly;
create trigger weekly_guard before insert or update on public.weekly for each row execute function public.check_weekly();

-- ========== 6. Champions et citation (v1.1) ==========
create table if not exists public.champions (
  week date primary key,                 -- lundi de la semaine gagnée
  uid uuid,
  sid text not null default '',
  pseudo text not null default '',
  xp integer not null default 0,
  quote text not null default '' check (char_length(quote) <= 120),
  quote_hidden boolean not null default false,   -- coche-la pour masquer une citation
  quote_at timestamptz
);
alter table public.champions enable row level security;
drop policy if exists "champions lisibles" on public.champions;
create policy "champions lisibles" on public.champions for select using (true);

-- Désigne (une seule fois) le champion de la semaine dernière, puis le renvoie
create or replace function public.weekly_champion()
returns jsonb language plpgsql security definer set search_path = public as $$
declare pw date := current_week() - 7; r champions; nm text;
begin
  insert into champions (week, uid, sid, pseudo, xp)
  select pw, w.uid, w.sid, w.pseudo, w.xp from (
    select distinct on (coalesce(nullif(sid, ''), uid::text)) uid, sid, pseudo, xp, updated_at
    from weekly where week = pw
    order by coalesce(nullif(sid, ''), uid::text), xp desc, updated_at asc) w
  where w.xp > 0
  order by w.xp desc, w.updated_at asc
  limit 1
  on conflict (week) do nothing;
  select * into r from champions where week = pw;
  if not found then return null; end if;
  select pseudo into nm from pseudos where owner = r.sid and r.sid <> '' limit 1;
  return jsonb_build_object('week', r.week, 'uid', r.uid, 'sid', r.sid, 'pseudo', coalesce(nm, r.pseudo), 'xp', r.xp,
                            'quote', case when r.quote_hidden then '' else r.quote end);
end $$;

-- Seul le champion en titre peut écrire sa citation
create or replace function public.set_champion_quote(p_code text, p_quote text)
returns text language plpgsql security definer set search_path = public as $$
declare pw date := current_week() - 7; r champions; q text;
begin
  select * into r from champions where week = pw;
  if not found then return 'aucun'; end if;
  if not (coalesce(r.sid <> '' and coalesce(p_code, '') ~ '^MTBX-' and r.sid = sid_of(p_code), false)
          or coalesce(r.uid = auth.uid(), false)) then
    return 'refuse';
  end if;
  q := btrim(regexp_replace(coalesce(p_quote, ''), '\s+', ' ', 'g'));
  if char_length(q) > 120 then return 'longueur'; end if;
  update champions set quote = q, quote_at = now(), quote_hidden = false where week = pw;
  return 'ok';
end $$;

-- ========== 7. Ma place au classement (v1.2) ==========
create or replace function public.my_ranks(p_sid text)
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (select coalesce(nullif(p_sid, ''), auth.uid()::text) as k),
  w as (select coalesce(nullif(sid, ''), uid::text) as k, max(xp) as xp,
               (array_agg(pseudo order by xp desc))[1] as pseudo
        from weekly where week = current_week() group by 1),
  a as (select coalesce(nullif(sid, ''), id::text) as k, max(xp) as xp,
               (array_agg(pseudo order by xp desc))[1] as pseudo
        from scores group by 1),
  mw as (select w.xp from w, me where w.k = me.k),
  ma as (select a.xp from a, me where a.k = me.k)
  select jsonb_build_object(
    'w_total', (select count(*) from w where xp > 0),
    'w_xp', (select xp from mw),
    'w_rank', (select 1 + count(*) from w where xp > coalesce((select xp from mw), 0)),
    'w_ahead', (select jsonb_build_object('pseudo', pseudo, 'xp', xp) from w
                where xp > coalesce((select xp from mw), 0) order by xp asc limit 1),
    'a_total', (select count(*) from a where xp > 0),
    'a_xp', (select xp from ma),
    'a_rank', (select 1 + count(*) from a where xp > coalesce((select xp from ma), 0)),
    'a_ahead', (select jsonb_build_object('pseudo', pseudo, 'xp', xp) from a
                where xp > coalesce((select xp from ma), 0) order by xp asc limit 1));
$$;

-- ========== 8. Défis entre amis (v1.2) ==========
create table if not exists public.defis (
  id text primary key check (id ~ '^[2-9A-HJKMNP-Z]{8}$'),
  voie text not null check (char_length(voie) between 1 and 20),
  mode text not null check (mode in ('a', 'i', 'm')),
  seed bigint not null check (seed between 0 and 4294967295),
  uid uuid not null default auth.uid() references auth.users (id) on delete cascade,
  sid text not null default '' check (char_length(sid) <= 16),
  pseudo text not null default '' check (char_length(pseudo) <= 20),
  score integer not null check (score between 0 and 200000),
  time_s integer not null check (time_s between 0 and 36000),
  splits jsonb not null default '[]' check (jsonb_typeof(splits) = 'array' and pg_column_size(splits) < 8000),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
alter table public.defis enable row level security;
drop policy if exists "defis lisibles" on public.defis;
drop policy if exists "creer son defi" on public.defis;
create policy "defis lisibles" on public.defis for select using (true);
create policy "creer son defi" on public.defis for insert to authenticated with check (auth.uid() = uid);
create index if not exists defis_uid_idx on public.defis (uid);
create index if not exists defis_sid_idx on public.defis (sid);
drop trigger if exists defis_pseudo on public.defis;
create trigger defis_pseudo before insert or update on public.defis for each row execute function public.check_pseudo();

create table if not exists public.defi_results (
  defi_id text not null references public.defis (id) on delete cascade,
  uid uuid not null default auth.uid() references auth.users (id) on delete cascade,
  sid text not null default '' check (char_length(sid) <= 16),
  pseudo text not null default '' check (char_length(pseudo) <= 20),
  score integer not null check (score between 0 and 200000),
  time_s integer not null check (time_s between 0 and 36000),
  won boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (defi_id, uid)
);
alter table public.defi_results enable row level security;
drop policy if exists "resultats lisibles" on public.defi_results;
drop policy if exists "envoyer son resultat" on public.defi_results;
create policy "resultats lisibles" on public.defi_results for select using (true);
create policy "envoyer son resultat" on public.defi_results for insert to authenticated with check (auth.uid() = uid);
create unique index if not exists defi_results_sid_uniq on public.defi_results (defi_id, sid) where sid <> '';
create index if not exists defi_results_uid_idx on public.defi_results (uid);

-- Un seul essai, pas sur son propre défi, pas après expiration ; « gagné » calculé par la base
create or replace function public.check_defi_result() returns trigger
language plpgsql security definer set search_path = public as $$
declare d defis;
begin
  select * into d from defis where id = new.defi_id;
  if not found then raise exception 'défi inconnu'; end if;
  if d.expires_at < now() then raise exception 'défi expiré'; end if;
  if d.uid = new.uid or (d.sid <> '' and d.sid = new.sid) then raise exception 'propre défi'; end if;
  new.won := new.score > d.score or (new.score = d.score and new.time_s < d.time_s);
  new.created_at := now();
  return new;
end $$;
drop trigger if exists defi_results_check on public.defi_results;
create trigger defi_results_check before insert on public.defi_results for each row execute function public.check_defi_result();
drop trigger if exists defi_results_pseudo on public.defi_results;
create trigger defi_results_pseudo before insert on public.defi_results for each row execute function public.check_pseudo();

-- ========== Droits ==========
revoke all on function public.save_progress(text, jsonb) from public;
revoke all on function public.load_progress(text) from public;
revoke all on function public.claim_pseudo(text, text) from public;
revoke all on function public.weekly_champion() from public;
revoke all on function public.set_champion_quote(text, text) from public;
grant execute on function public.save_progress(text, jsonb) to anon, authenticated;
grant execute on function public.load_progress(text) to anon, authenticated;
grant execute on function public.claim_pseudo(text, text) to anon, authenticated;
grant execute on function public.weekly_champion() to anon, authenticated;
grant execute on function public.set_champion_quote(text, text) to anon, authenticated;
revoke all on function public.my_ranks(text) from public;
grant execute on function public.my_ranks(text) to anon, authenticated;
