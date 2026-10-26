-- =============================================================
--  SEIMEI · EXAMENS : base de données Supabase
--  À coller en entier dans Supabase → SQL Editor → New query → Run.
--  Le script peut être relancé sans risque : il ne touche ni aux
--  questions ni aux résultats déjà enregistrés.
--
--  Le dépôt GitHub est public : ce fichier ne contient ni les
--  questions (prive/questions.sql, gardé hors du dépôt) ni le code
--  de la gérance (défini avec definir_code_gerance, voir CLAUDE.md).
-- =============================================================

-- Réglages de l'examen (une seule ligne : Table Editor → reglages)
create table if not exists public.reglages (
  id                    int  primary key default 1 check (id = 1),
  titre                 text not null default 'Examen de passage d’observateur à infirmier',
  nb_eliminatoires      int  not null default 2  check (nb_eliminatoires between 0 and 10),
  nb_questions          int  not null default 15 check (nb_questions between 1 and 60),
  secondes_par_question int  not null default 15 check (secondes_par_question between 5 and 120),
  seuil_reussite        int  not null default 12,       -- bonnes réponses minimum sur nb_questions
  afficher_resultat     boolean not null default false, -- true : le candidat voit son résultat à la fin
  code_gerance_hash     text                            -- empreinte du code, jamais le code lui-même
);
insert into public.reglages (id) values (1) on conflict (id) do nothing;

-- Banque de questions (remplie par prive/questions.sql)
create table if not exists public.questions (
  id       text primary key,                  -- E01… éliminatoires, Q01… cours
  type     text not null check (type in ('elim', 'std')),
  theme    text not null,
  texte    text not null,
  bonne    text not null,                     -- la bonne réponse
  fausses  text[] not null check (cardinality(fausses) between 1 and 5),
  tri_num  boolean not null default false,    -- choix chiffrés : affichés dans l'ordre croissant
  actif    boolean not null default true      -- false : la question n'est plus tirée
);

-- Passages d'examen
create table if not exists public.passages (
  id        text primary key,                 -- EX-XXXXXXXX
  nom       text not null,
  prenom    text not null,
  debut     timestamptz not null default now(),
  fin       timestamptz,
  statut    text not null default 'En cours' check (statut in ('En cours', 'Terminé')),
  tirage    jsonb not null,                   -- questions tirées et ordre des choix (interne)
  score     int,
  elim      int,
  resultat  text check (resultat in ('Réussi', 'Échoué', 'Éliminé')),
  duree     int,                              -- secondes entre le début et l'envoi
  sorties   int  not null default 0,          -- sorties de la page pendant l'examen
  alertes   text not null default '',
  detail    jsonb                             -- question, réponse donnée, bonne réponse, temps
);
create index if not exists passages_par_debut on public.passages (debut desc);

-- Essais ratés du code de la gérance (freine les essais à répétition)
create table if not exists public.essais_code (
  id  bigint generated always as identity primary key,
  le  timestamptz not null default now()
);

-- Sécurité : personne ne lit ni n'écrit les tables directement.
-- Le site passe uniquement par les fonctions plus bas.
alter table public.reglages    enable row level security;
alter table public.questions   enable row level security;
alter table public.passages    enable row level security;
alter table public.essais_code enable row level security;
revoke all on table public.reglages, public.questions, public.passages, public.essais_code from anon, authenticated;

-- =============================================================
--  Outils internes (non appelables depuis le site)
-- =============================================================

create or replace function public.seimei_nettoyer(p text)
returns text language sql immutable set search_path = ''
as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', '', 'g'), '\s+', ' ', 'g')), 40);
$$;

create or replace function public.seimei_premier_nombre(p text)
returns int language sql immutable set search_path = ''
as $$
  select coalesce((regexp_match(p, '\d{1,9}'))[1]::int, 0);
$$;

create or replace function public.seimei_empreinte(p text)
returns text language sql immutable set search_path = ''
as $$
  select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex');
$$;

-- Null si le code est bon, sinon le message à afficher. Un essai raté est noté
-- (la fonction renvoie un message au lieu d'une erreur pour que la note soit gardée).
create or replace function public.seimei_controle_code(p_code text)
returns text language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_empreinte text;
begin
  select code_gerance_hash into v_empreinte from public.reglages where id = 1;
  if v_empreinte is null then
    return 'Le code de la gérance n’est pas encore défini dans Supabase.';
  end if;
  delete from public.essais_code where le < now() - interval '1 day';
  if (select count(*) from public.essais_code where le > now() - interval '15 minutes') >= 30 then
    return 'Trop d’essais ratés : réessayez dans 15 minutes.';
  end if;
  if public.seimei_empreinte(p_code) = v_empreinte then
    return null;
  end if;
  insert into public.essais_code default values;
  perform pg_sleep(1);
  return 'Code d’accès incorrect.';
end $$;

create or replace function public.seimei_reponse_candidat(p_id text, p_resultat text, p_score int, p_elim int)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case when r.afficher_resultat
    then jsonb_build_object('id', p_id, 'resultat', p_resultat, 'score', p_score, 'elim', p_elim,
                            'nbQuestions', r.nb_questions, 'nbElim', r.nb_eliminatoires)
    else jsonb_build_object('id', p_id)
  end
  from public.reglages r where r.id = 1;
$$;

-- À lancer soi-même dans le SQL Editor (jamais depuis le site) :
--   select public.definir_code_gerance('ton-code-secret');
create or replace function public.definir_code_gerance(p_code text)
returns text language plpgsql volatile security definer set search_path = ''
as $$
begin
  if length(coalesce(p_code, '')) < 6 then
    raise exception 'Choisis un code d’au moins 6 caractères.';
  end if;
  update public.reglages set code_gerance_hash = public.seimei_empreinte(p_code) where id = 1;
  delete from public.essais_code;
  return 'Code de la gérance enregistré.';
end $$;

-- =============================================================
--  Fonctions appelées par le site
-- =============================================================

create or replace function public.infos_examen()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('titre', titre, 'nbElim', nb_eliminatoires,
                            'nbQuestions', nb_questions, 'secondes', secondes_par_question)
  from public.reglages where id = 1;
$$;

-- Tire les questions, ouvre le passage et renvoie l'examen SANS les bonnes réponses.
create or replace function public.demarrer_examen(p_nom text, p_prenom text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  r         public.reglages;
  q         public.questions;
  v_nom     text := public.seimei_nettoyer(p_nom);
  v_prenom  text := public.seimei_nettoyer(p_prenom);
  v_id      text;
  v_choix   text[];
  v_ordre   int[];
  v_tirage  jsonb := '[]';
  v_liste   jsonb := '[]';
begin
  if v_nom = '' or v_prenom = '' then
    raise exception 'Indiquez votre nom et votre prénom.';
  end if;
  if (select count(*) from public.passages where debut > now() - interval '1 minute') >= 30 then
    raise exception 'Trop d’examens lancés en même temps : réessayez dans une minute.';
  end if;
  select * into r from public.reglages where id = 1;

  for q in
    select * from (
      (select * from public.questions where type = 'elim' and actif order by random() limit r.nb_eliminatoires)
      union all
      (select * from public.questions where type = 'std' and actif order by random() limit r.nb_questions)
    ) t
    order by random()
  loop
    v_choix := array[q.bonne] || q.fausses;          -- position 1 = bonne réponse
    select array_agg(i order by case when q.tri_num then public.seimei_premier_nombre(v_choix[i]) end, random())
      into v_ordre
      from generate_subscripts(v_choix, 1) as i;
    v_tirage := v_tirage || jsonb_build_object('id', q.id, 'type', q.type, 'ordre', to_jsonb(v_ordre));
    v_liste := v_liste || jsonb_build_object(
      'type', q.type, 'theme', q.theme, 'texte', q.texte,
      'options', (select jsonb_agg(v_choix[o.i] order by o.n) from unnest(v_ordre) with ordinality as o(i, n)));
  end loop;

  if jsonb_array_length(v_liste) = 0 then
    raise exception 'La banque de questions est vide.';
  end if;

  v_id := 'EX-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
  insert into public.passages (id, nom, prenom, tirage) values (v_id, v_nom, v_prenom, v_tirage);
  return jsonb_build_object('id', v_id, 'secondes', r.secondes_par_question, 'questions', v_liste);
end $$;

-- Corrige et enregistre le passage. p_reponses[i] = {"choix": index affiché ou null, "ms": temps}.
-- Un second envoi du même passage renvoie le premier résultat sans rien changer.
create or replace function public.terminer_examen(p_id text, p_reponses jsonb, p_sorties int)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  r          public.reglages;
  p          public.passages;
  q          public.questions;
  t          record;
  v_choix    text[];
  v_rep      jsonb;
  v_c        int;
  v_k        int;
  v_ms       int;
  v_ok       boolean;
  v_type     text;
  v_limite   int;
  v_score    int := 0;
  v_elim     int := 0;
  v_nb_elim  int := 0;
  v_trop_lent boolean := false;
  v_duree    int;
  v_max      int;
  v_alertes  text[] := '{}';
  v_detail   jsonb := '[]';
  v_resultat text;
begin
  select * into p from public.passages where id = p_id for update;
  if not found then
    raise exception 'Passage introuvable. Recommencez l’examen depuis l’accueil.';
  end if;
  if p.statut = 'Terminé' then
    return public.seimei_reponse_candidat(p.id, p.resultat, p.score, p.elim);
  end if;
  select * into r from public.reglages where id = 1;
  v_limite := r.secondes_par_question * 1000;

  for t in select e.item, e.n from jsonb_array_elements(p.tirage) with ordinality as e(item, n) loop
    v_type := t.item ->> 'type';
    if v_type = 'elim' then
      v_nb_elim := v_nb_elim + 1;
    end if;
    select * into q from public.questions where id = t.item ->> 'id';
    if q.id is null then
      v_detail := v_detail || jsonb_build_object('qid', t.item ->> 'id', 'type', v_type, 'theme', '—',
        'question', '(question retirée de la banque)', 'options', null, 'choix', null,
        'reponse', null, 'bonne', '—', 'correct', false, 'ms', 0);
      continue;
    end if;

    v_choix := array[q.bonne] || q.fausses;
    v_rep := coalesce(p_reponses -> (t.n::int - 1), '{}');
    v_c := case when jsonb_typeof(v_rep -> 'choix') = 'number' then floor((v_rep ->> 'choix')::numeric)::int end;
    v_k := case when v_c between 0 and jsonb_array_length(t.item -> 'ordre') - 1
                then (t.item -> 'ordre' ->> v_c)::int end;
    v_ok := coalesce(v_k = 1, false);
    v_ms := case when jsonb_typeof(v_rep -> 'ms') = 'number'
                 then greatest(0, least(round((v_rep ->> 'ms')::numeric), 3600000))::int else 0 end;
    if v_ms > v_limite + 1000 then
      v_trop_lent := true;
    end if;
    if v_ok then
      if v_type = 'elim' then v_elim := v_elim + 1; else v_score := v_score + 1; end if;
    end if;
    -- options : les choix dans l'ordre où le candidat les a vus ; choix : la position qu'il a cochée
    v_detail := v_detail || jsonb_build_object('qid', q.id, 'type', v_type, 'theme', q.theme, 'question', q.texte,
      'options', (select jsonb_agg(v_choix[o.k::int] order by o.n)
                    from jsonb_array_elements_text(t.item -> 'ordre') with ordinality as o(k, n)),
      'choix', case when v_k is null then null else v_c end,
      'reponse', case when v_k is null then null else v_choix[v_k] end,
      'bonne', q.bonne, 'correct', v_ok, 'ms', least(v_ms, v_limite));
  end loop;

  v_duree := round(extract(epoch from now() - p.debut))::int;
  v_max := jsonb_array_length(p.tirage) * r.secondes_par_question + 60;
  if v_duree > v_max then
    v_alertes := v_alertes || format('Envoi tardif : %s s entre le début et l’envoi (%s s au maximum attendus)', v_duree, v_max);
  end if;
  if v_trop_lent then
    v_alertes := v_alertes || 'Temps de réponse supérieur à la limite (page modifiée ?)'::text;
  end if;
  v_resultat := case when v_elim < v_nb_elim then 'Éliminé'
                     when v_score >= r.seuil_reussite then 'Réussi'
                     else 'Échoué' end;

  update public.passages set
    fin = now(), statut = 'Terminé', score = v_score, elim = v_elim, resultat = v_resultat,
    duree = v_duree, sorties = greatest(0, least(coalesce(p_sorties, 0), 999)),
    alertes = array_to_string(v_alertes, ' · '), detail = v_detail
  where id = p.id;

  return public.seimei_reponse_candidat(p.id, v_resultat, v_score, v_elim);
end $$;

-- Tous les passages, du plus récent au plus ancien (onglet Gérance).
create or replace function public.lire_resultats(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_erreur text := public.seimei_controle_code(p_code);
  r        public.reglages;
begin
  if v_erreur is not null then
    return jsonb_build_object('erreur', v_erreur);
  end if;
  select * into r from public.reglages where id = 1;
  return jsonb_build_object(
    'seuil', r.seuil_reussite, 'nbQuestions', r.nb_questions, 'nbElim', r.nb_eliminatoires,
    'secondes', r.secondes_par_question,
    'passages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'nom', p.nom, 'prenom', p.prenom, 'statut', p.statut,
        'debut', floor(extract(epoch from p.debut) * 1000),
        'fin', floor(extract(epoch from p.fin) * 1000),
        'score', p.score, 'elim', p.elim, 'resultat', p.resultat, 'duree', p.duree,
        'sorties', p.sorties, 'alertes', p.alertes, 'detail', coalesce(p.detail, '[]'))
        order by p.debut desc)
      from public.passages p), '[]'));
end $$;

create or replace function public.supprimer_passage(p_code text, p_id text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_erreur text := public.seimei_controle_code(p_code);
begin
  if v_erreur is not null then
    return jsonb_build_object('erreur', v_erreur);
  end if;
  delete from public.passages where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- =============================================================
--  Banque de questions (onglet Gérance → Banque de questions)
-- =============================================================

create or replace function public.lire_questions(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_erreur text := public.seimei_controle_code(p_code);
begin
  if v_erreur is not null then
    return jsonb_build_object('erreur', v_erreur);
  end if;
  return jsonb_build_object('questions', coalesce((
    select jsonb_agg(jsonb_build_object('id', q.id, 'type', q.type, 'theme', q.theme, 'texte', q.texte,
      'bonne', q.bonne, 'fausses', to_jsonb(q.fausses), 'triNum', q.tri_num, 'actif', q.actif)
      order by q.type, length(q.id), q.id)
    from public.questions q), '[]'));
end $$;

-- Ajoute une question (sans « id ») ou modifie celle dont l'id est donné.
-- p_question = {"id", "type": "elim"|"std", "theme", "texte", "bonne", "fausses": [3 textes], "triNum", "actif"}
create or replace function public.enregistrer_question(p_code text, p_question jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_erreur  text := public.seimei_controle_code(p_code);
  v_id      text := nullif(btrim(coalesce(p_question ->> 'id', '')), '');
  v_type    text := p_question ->> 'type';
  v_theme   text := left(btrim(coalesce(p_question ->> 'theme', '')), 60);
  v_texte   text := left(btrim(coalesce(p_question ->> 'texte', '')), 300);
  v_bonne   text := left(btrim(coalesce(p_question ->> 'bonne', '')), 200);
  v_tri     boolean := coalesce(p_question ->> 'triNum', 'false') = 'true';
  v_actif   boolean := coalesce(p_question ->> 'actif', 'true') = 'true';
  v_fausses text[] := '{}';
  v_prefixe text;
begin
  if v_erreur is not null then
    return jsonb_build_object('erreur', v_erreur);
  end if;
  if v_type is null or v_type not in ('elim', 'std') then
    return jsonb_build_object('erreur', 'Choisis la liste : questions du cours ou éliminatoires.');
  end if;
  if jsonb_typeof(p_question -> 'fausses') = 'array' then
    select coalesce(array_agg(left(btrim(f.x), 200) order by f.n), '{}') into v_fausses
      from jsonb_array_elements_text(p_question -> 'fausses') with ordinality as f(x, n)
      where btrim(f.x) <> '';
  end if;
  if v_texte = '' then
    return jsonb_build_object('erreur', 'Écris la question.');
  end if;
  if v_bonne = '' then
    return jsonb_build_object('erreur', 'Indique la bonne réponse.');
  end if;
  if cardinality(v_fausses) <> 3 then
    return jsonb_build_object('erreur', 'Indique trois mauvaises réponses.');
  end if;
  if (select count(distinct lower(x)) from unnest(array[v_bonne] || v_fausses) as x) <> 4 then
    return jsonb_build_object('erreur', 'Les quatre réponses doivent être différentes.');
  end if;
  if v_theme = '' then
    if v_type = 'elim' then
      v_theme := 'Organisation de la Seimei';
    else
      return jsonb_build_object('erreur', 'Indique le thème de la question.');
    end if;
  end if;

  if v_id is null then
    v_prefixe := case when v_type = 'elim' then 'E' else 'Q' end;
    select v_prefixe || lpad((coalesce(max(substring(id from 2)::int), 0) + 1)::text, 2, '0')
      into v_id
      from public.questions where id ~ ('^' || v_prefixe || '[0-9]{1,6}$');
    insert into public.questions (id, type, theme, texte, bonne, fausses, tri_num, actif)
      values (v_id, v_type, v_theme, v_texte, v_bonne, v_fausses, v_tri, v_actif);
  else
    update public.questions
      set type = v_type, theme = v_theme, texte = v_texte, bonne = v_bonne,
          fausses = v_fausses, tri_num = v_tri, actif = v_actif
      where id = v_id;
    if not found then
      return jsonb_build_object('erreur', 'Cette question n’existe plus : actualise la liste.');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Les résultats déjà enregistrés gardent le texte de la question supprimée.
create or replace function public.supprimer_question(p_code text, p_id text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_erreur text := public.seimei_controle_code(p_code);
begin
  if v_erreur is not null then
    return jsonb_build_object('erreur', v_erreur);
  end if;
  delete from public.questions where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- =============================================================
--  Droits : le site (rôle anon) n'appelle que les fonctions publiques
-- =============================================================
revoke execute on function
  public.seimei_nettoyer(text), public.seimei_premier_nombre(text), public.seimei_empreinte(text),
  public.seimei_controle_code(text), public.seimei_reponse_candidat(text, text, int, int),
  public.definir_code_gerance(text)
  from public, anon, authenticated;

grant execute on function
  public.infos_examen(), public.demarrer_examen(text, text), public.terminer_examen(text, jsonb, int),
  public.lire_resultats(text), public.supprimer_passage(text, text),
  public.lire_questions(text), public.enregistrer_question(text, jsonb), public.supprimer_question(text, text)
  to anon, authenticated;

notify pgrst, 'reload schema';
