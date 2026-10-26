# Seimei · Examens : contexte du projet

Site d’examens internes de la **Seimei**, corps médical de Suna, pour une communauté de roleplay inspirée de Naruto. Tout est en français. Premier examen : **passage d’observateur à infirmier**.

- En ligne : https://lune-ecl.github.io/Seimei-examen/ (GitHub Pages, branche `main`, racine)
- Base de données : Supabase. URL et clé publique (`sb_publishable_…`) dans `CONFIG`, en haut du script de `index.html`. Ne jamais utiliser la clé secrète.

## Fichiers
- `index.html` : tout le site (HTML, CSS et JS dans un seul fichier, aucune étape de build). `@supabase/supabase-js@2.117.2` est chargé depuis jsDelivr. Si `SUPABASE_URL` est vide, un bandeau l’indique et l’examen ne démarre pas.
- `schema.sql` : tables, sécurité (RLS) et fonctions. À coller dans Supabase → SQL Editor → Run. Relançable sans risque (ne touche ni aux questions ni aux résultats).
- `prive/questions.sql` : les 50 questions **avec leurs réponses**. **Jamais dans le dépôt** (`.gitignore`), car le dépôt est public. À lancer une fois après `schema.sql`.
- `test-local/` (ignoré) : banc d’essai local avec un vrai Postgres dans le navigateur (PGlite) qui exécute `schema.sql` et `prive/questions.sql`, plus `tests.html` (tests du SQL et des droits).

## Fonctionnement
- **Examen** : 2 questions éliminatoires (tirées parmi 10, organisation de la Seimei) + 15 questions (tirées parmi 40, cours « Les fondamentaux de la médecine »). Ordre des questions et des choix mélangé à chaque passage (les choix chiffrés restent dans l’ordre croissant, `tri_num`). QCU, 15 s par question, pas de retour en arrière ; à zéro, la réponse cochée compte. Réussite : au moins 12/15 **et** aucune erreur aux éliminatoires.
- **Aucun compte** : nom + prénom → `demarrer_examen` (ouvre le passage, statut « En cours ») → compte à rebours de 3 s → questions → `terminer_examen` corrige **côté serveur**. Le navigateur ne reçoit jamais les bonnes réponses. Le candidat ne voit pas son résultat, sauf si `reglages.afficher_resultat = true`.
- **Gérance** : onglet scellé par un code (`lire_resultats(code)`, `supprimer_passage(code, id)`). Le code n’est stocké que sous forme d’empreinte (`reglages.code_gerance_hash`) et se définit dans le SQL Editor : `select public.definir_code_gerance('…');`. Un mauvais code fait patienter 1 s ; 30 essais ratés en 15 min bloquent l’accès 15 min (redéfinir le code lève le blocage). Tableau : tuiles-filtres, taux de réussite, répartition des scores, questions les plus ratées, liste des passages (tentatives d’un même nom numérotées), détail par question, suppression avec confirmation.
- **Sécurité** : les tables ne sont lisibles ni modifiables par personne (RLS sans politique + `revoke`). Le site (rôle `anon`) n’appelle que 5 fonctions `security definer` : `infos_examen`, `demarrer_examen`, `terminer_examen`, `lire_resultats`, `supprimer_passage`. Les outils internes (`seimei_*`) et `definir_code_gerance` ne lui sont pas accessibles. Limite : 30 examens démarrés par minute.
- **Alertes** pour la gérance : sorties de page pendant l’examen (`visibilitychange`), envoi tardif (plus de nb × secondes + 60 s), temps de réponse incohérent. Un passage « En cours » depuis plus de 10 min s’affiche « Interrompu ».
- **Réglages** (Table Editor → `reglages`) : `nb_eliminatoires`, `nb_questions`, `secondes_par_question`, `seuil_reussite`, `afficher_resultat`, `titre`.
- **Questions** (Table Editor → `questions`) : `bonne`, `fausses` (3 choix), `theme`, `actif` (false = plus tirée). Mettre à jour les éliminatoires quand la gérance ou une branche change.
- **Thème** : nuit sur le désert de Suna (vert du chakra médical, or du sable, vermillon des sceaux), polices Shippori Mincho B1, Zen Kaku Gothic New, Yuji Syuku (kanjis 医 封 試 時 断 集), sable animé sur canvas, emblème tournant, chrono en anneau, tampon 医 à la fin, sceau 封 de la gérance. Mode téléphone ≤ 760 px : chrono collé sous l’en-tête (`--haut-tete` mesuré en JS). Animations coupées si « réduire les animations » est activé.

## Mise en place
1. Supabase → SQL Editor : coller `schema.sql` → Run, puis `prive/questions.sql` → Run.
2. SQL Editor : `select public.definir_code_gerance('ton-code');` (6 caractères minimum).
3. Renseigner `CONFIG.SUPABASE_URL` dans `index.html` (Project Settings → Data API → Project URL), puis pousser sur `main`.
