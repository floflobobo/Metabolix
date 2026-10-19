-- Metabolix : base du classement et des signalements.
-- À coller dans Supabase > SQL Editor > New query, puis « Run ». Une seule fois.

-- 1. Classement : une ligne par joueur (joueur anonyme, identifié par son navigateur)
create table if not exists public.scores (
  id uuid primary key references auth.users (id) on delete cascade,
  pseudo text not null default '' check (char_length(pseudo) <= 20),
  xp integer not null default 0 check (xp between 0 and 5000000),
  stars integer not null default 0 check (stars between 0 and 90),
  rank text not null default '' check (char_length(rank) <= 30),
  updated_at timestamptz not null default now()
);
alter table public.scores enable row level security;

-- Tout le monde peut lire le classement
create policy "classement lisible" on public.scores
  for select using (true);
-- Chacun ne peut créer et modifier QUE sa propre ligne
create policy "creer sa ligne" on public.scores
  for insert to authenticated with check (auth.uid() = id);
create policy "modifier sa ligne" on public.scores
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create index if not exists scores_xp_idx on public.scores (xp desc);

-- 2. Signalements d'erreurs : les joueurs écrivent, seul toi les lis (dans Table Editor)
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  voie text not null default '' check (char_length(voie) <= 80),
  texte text not null check (char_length(texte) between 3 and 1000),
  user_id uuid default auth.uid()
);
alter table public.reports enable row level security;

create policy "envoyer un signalement" on public.reports
  for insert to authenticated with check (true);
-- Aucune politique de lecture : les signalements ne sont visibles que depuis ton tableau de bord.
