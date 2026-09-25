# Procédure — rotation du `client_secret`, et mise en conformité de la console

Ce document est une **procédure d'exploitation**, pas de la documentation d'architecture. Il ne
contient aucun secret et ne doit jamais en contenir.

---

## Pourquoi cette procédure existe

Trois raisons se superposent, et il faut les distinguer parce qu'elles n'ont pas le même délai.

1. **Une obligation contractuelle.** Developer Terms §3.2 impose au développeur de « Implement
   industry-standard security (e.g., **TLS 1.2+**, encryption at rest, least-privilege access,
   **secret rotation**) ». La rotation n'est donc pas une bonne pratique facultative.

2. **Une divulgation réelle.** Le `client_secret` a été collé dans une conversation. Il n'a été ni
   répété, ni enregistré, ni utilisé — un motif `qfcs_` cherché dans l'arbre de travail, dans tout
   l'historique git (`git log --all -S`), dans les fichiers suivis et dans la mémoire rend **0
   occurrence** partout. Il n'en reste pas moins qu'un secret transmis à un tiers est un secret
   divulgué, et qu'il ne se remplace pas comme un mot de passe : il faut que **l'ancien cesse d'être
   accepté**.

3. **Un délai de 24 heures.** §3.2 impose aussi de « Promptly (within **24 hours**) report to
   **developers@quran.com** any actual or suspected unauthorised access, security breach, or **data
   exposure related to the APIs** ». Un identifiant d'API divulgué entre dans cette définition.

---

## Ce que je n'ai pas pu vérifier, et ce que cela change

La console est derrière une connexion OAuth : ses écrans ne sont pas lisibles sans votre compte, et
la documentation publique **ne décrit nulle part** la rotation ni la régénération du secret. Elle
décrit le secret comme « a **one-time** `client_secret` ».

Conséquence directe : **je ne peux pas vous dire quel bouton cliquer**, et je ne vais pas
l'inventer. La procédure se dédouble donc à l'étape 1.3, selon ce que vous trouverez à l'écran.

---

## Partie 0 — Avant de toucher à quoi que ce soit

**0.1 — Confirmer qu'aucun secret n'est dans le dépôt.** À relancer *après* la rotation, pas
seulement avant :

```bash
cd soumaya
grep -rn "qfcs_" . 2>/dev/null || echo "aucun secret dans l'arbre de travail"
git log --all -S "qfcs_" --oneline || echo "aucun secret dans l'historique"
```

**0.2 — Noter la valeur actuelle du `client_id`.** Il n'est **pas** un secret, et il change ou non
selon la branche suivie à l'étape 1.3. S'il change, il faudra mettre à jour `QF_CLIENT_ID` aussi :

```bash
grep -c . ~/.soumaya-qf.env 2>/dev/null && grep -o "QF_CLIENT_ID=.*" ~/.soumaya-qf.env || echo "(pas encore de fichier d'environnement)"
```

---

## Partie 1 — Faire tourner le `client_secret`

### 1.1 — Se connecter à la console

Ouvrir <https://dev-console.quran.foundation/projects> et cliquer sur **Continue with
Quran.Foundation**. C'est une connexion OAuth : la console ouvre une session pour ce navigateur.

### 1.2 — Ouvrir la bonne application

Dans la liste des projets, ouvrir l'application **Soumaya**. Vérifier au passage que son type est
bien **Backend/server app** — un client *Frontend or mobile app* n'a **pas** de `client_secret`, et
le flux `client_credentials` y est impossible. Si le type est faux, il n'y a pas de secret à
tourner : il faut recréer un client.

### 1.3 — Chercher le contrôle de rotation

Sur l'écran des identifiants de l'application, chercher un libellé parmi : **Rotate**, **Regenerate**,
**Reset secret**, **New secret**, **Roll credentials**.

**Branche A — le contrôle existe.** Cliquer dessus. Le nouveau secret s'affiche **une seule fois**.
Le copier immédiatement (étape 1.4) : s'il est perdu, il faut recommencer. Le `client_id` ne change
pas.

**Branche B — aucun contrôle de ce genre.** Le secret est alors réellement à usage unique, et la
seule rotation possible est de **créer une nouvelle application Backend/server**, puis d'abandonner
l'ancienne. Cela change **aussi** le `client_id` — d'où l'étape 0.2. Dans ce cas, penser à reporter
les deux URL de la partie 3 sur la nouvelle application, et à supprimer l'ancienne pour que son
secret ne soit plus accepté.

### 1.4 — Ranger le nouveau secret hors du dépôt

Jamais dans un fichier suivi, jamais en argument de ligne de commande — un argument reste dans
l'historique du shell. Un fichier d'environnement hors du dépôt :

```bash
cat > ~/.soumaya-qf.env <<'EOF'
QF_CLIENT_ID=<le client_id>
QF_CLIENT_SECRET=<le nouveau secret>
EOF
```

Sous Windows, `chmod` ne restreint pas réellement l'accès : le fichier est protégé par les
autorisations du dossier personnel. Ne pas le placer dans un dossier synchronisé (OneDrive, Dropbox).

### 1.5 — Faire prendre le nouveau secret au proxy

Le proxy lit `QF_CLIENT_SECRET` dans son environnement : il ne verra rien tant qu'il n'est pas
relancé avec le fichier chargé.

```bash
set -a; . ~/.soumaya-qf.env; set +a
node platform/proxy/qf-token-proxy.mjs &
curl -s http://127.0.0.1:8787/health
```

### 1.6 — Prouver la rotation — l'étape qui compte

C'est ici que la plupart des rotations sont crues faites sans l'être. Le contrôle exige **deux**
verdicts : le nouveau secret accepté, **et l'ancien refusé**.

```bash
set -a; . ~/.soumaya-qf.env; set +a
QF_ANCIEN_SECRET="<l'ancien secret>" python tools/verifier_identifiants_qf.py
```

Sortie attendue :

```
  ok    courant  empreinte a1b2c3d4e5f6  HTTP 200 attendu accepte, obtenu accepte — jeton valable 3600 s
  ok    ancien   empreinte 9f8e7d6c5b4a  HTTP 401 attendu refuse, obtenu refuse — invalid_client

Rotation prouvee — le secret courant est accepte, l'ancien est refuse.
```

Les deux **empreintes doivent différer** : c'est ce qui établit qu'on a bien éprouvé deux chaînes
distinctes, sans jamais afficher ni l'une ni l'autre.

Trois lectures à ne pas confondre :

| Ce que vous lisez | Ce que cela veut dire |
|---|---|
| `[secret-vivant]` | La rotation n'a pas eu lieu, ou elle n'a porté que sur autre chose. **L'ancien secret fonctionne encore.** |
| `[secret-refuse]` sur le courant | Le nouveau secret est faux, mal recopié, ou la rotation n'a pas été validée. |
| `[mesure-impossible]` | Ni un refus ni une acceptation : le réseau ou un proxy a échoué. **Ne rien en conclure**, relancer. |

### 1.7 — Ce que la rotation ne fait pas

- Les **jetons déjà émis** avec l'ancien secret restent valides jusqu'à leur expiration, soit
  **3600 s**. La révocation n'est pas instantanée.
- Le proxy protège le **secret**, pas le **quota**. Un proxy ouvert laisse quiconque consommer le
  quota du projet. Fermer complètement demanderait une attestation d'application (Firebase App
  Check, Play Integrity, DeviceCheck).

---

## Partie 2 — Signaler l'exposition (§3.2, sous 24 h)

À envoyer à **developers@quran.com**. Le délai court depuis la divulgation, pas depuis la rotation :
ne pas attendre d'avoir tout terminé. Brouillon :

> Objet : Credential exposure — Soumaya (Quran Foundation Content API v4)
>
> Hello,
>
> I am the developer of Soumaya, a Quran reading and memorization application built on the Quran
> Foundation Content API v4 (client `…`, Backend/server app).
>
> I am reporting a credential exposure as required by Developer Terms §3.2. My `client_secret` was
> inadvertently disclosed in a private note-taking context on 25 September 2026. The secret was
> never published, committed, or used by any third party to my knowledge — I verified that it
> appears nowhere in my public repository, in its git history, or in any tracked file.
>
> I rotated the secret on 25 September 2026 and verified that the previous secret is no longer
> accepted by the token endpoint. The `client_id` is unchanged.
>
> Please let me know if any further action is required on my side.
>
> Regards,
> Mohamed C

Remplacer `…` par le `client_id` si vous jugez utile de l'inclure ; il n'est pas secret. **Ne
jamais joindre le secret, ni l'ancien ni le nouveau.**

---

## Partie 3 — Les deux adresses exigées, dans la console

### 3.1 — Ce qui est exigé

§3.2 : « Provide a publicly reachable **Privacy Policy** and **Terms of Use** for the Application.
This Privacy Policy must, at a minimum, incorporate all principles and requirements set forth in the
QF Developer Privacy Policy Requirements. »

### 3.2 — Vérifier que vos pages satisfont le paquet

Avant de coller une adresse dans la console, s'assurer que la page derrière tient ses promesses :

```bash
python tools/verifier_conformite.py
```

Attendu : `34 exigence(s), 34 verification(s). Aucun defaut — chaque exigence est satisfaite, ou
declaree sans objet avec sa raison.`

### 3.3 — Les valeurs exactes à coller

| Champ de la console | Valeur |
|---|---|
| Privacy Policy URL | `https://msoumaya2019.github.io/SoumayaQuran/privacy/` |
| Terms of Service URL | `https://msoumaya2019.github.io/SoumayaQuran/terms/` |

La barre oblique finale compte : sans elle, GitHub Pages redirige, et certains validateurs traitent
une redirection comme une adresse non joignable.

### 3.4 — Où les coller

Sur l'écran de l'application, dans la console. Les libellés attendus sont **Privacy Policy URL** et
**Terms of Service URL**. Si votre application a été créée avant que ces champs n'existent, ils se
trouvent dans les réglages de l'application ; si vous ne les trouvez pas, la branche B de l'étape
1.3 (créer une nouvelle application) est l'occasion de les renseigner à la création.

### 3.5 — Vérifier que les adresses sont joignables

Depuis n'importe quel navigateur, **sans être connecté à quoi que ce soit** — c'est le sens de
« publicly reachable » :

```bash
python tools/verifier_pages_en_ligne.py
```

Attendu : trois pages en `200`, identiques au dépôt, et chaque lien interne résolu.

---

## Partie 4 — Optionnel : réduire la portée du jeton GitHub

Le jeton qui sert au `git push` est un jeton **classique** de portée `repo` : un accès d'écriture
large sur **tous** vos dépôts, conservé en clair dans le gestionnaire d'identifiants de Windows. Le
remplacer par un jeton à portée fine réduit ce qui serait perdu s'il fuyait.

1. Ouvrir <https://github.com/settings/personal-access-tokens/new>.
2. **Repository access** → *Only select repositories* → `SoumayaQuran`.
3. **Permissions** :
   - `Contents` → *Read and write* (nécessaire au `git push`) ;
   - `Actions` → *Read* (pour lire l'état de la CI) ;
   - `Pages` → *Read and write* (pour piloter la publication) ;
   - `Metadata` → *Read* (imposé).
4. Générer, copier le jeton, puis remplacer l'identifiant stocké :

```bash
cmdkey /list | grep -i github          # voir ce qui est stocké
cmdkey /delete:git:https://github.com  # retirer l'ancien
```

Le `git push` suivant demandera un mot de passe : y coller le nouveau jeton. Ensuite, vérifier que
la CI répond toujours :

```bash
printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep -c "^password="
```

---

## Récapitulatif — la liste à cocher

- [ ] **0.1** — aucun `qfcs_` dans l'arbre de travail ni dans l'historique git
- [ ] **1.3** — contrôle de rotation trouvé (branche A) ou nouvelle application créée (branche B)
- [ ] **1.4** — nouveau secret rangé dans `~/.soumaya-qf.env`, hors du dépôt
- [ ] **1.5** — proxy relancé avec le nouveau secret
- [ ] **1.6** — `verifier_identifiants_qf.py` : **courant accepté, ancien refusé**
- [ ] **2** — exposition signalée à `developers@quran.com` (sous 24 h)
- [ ] **3.2** — `verifier_conformite.py` vert
- [ ] **3.3** — les deux adresses collées dans la console
- [ ] **3.5** — `verifier_pages_en_ligne.py` vert
- [ ] **4** — *(optionnel)* jeton GitHub à portée fine

---

## Ce qui reste vrai après cette procédure

- **Rien n'a encore tourné sur un appareil physique.** La rotation ne change pas cela : l'audio, la
  synchronisation verset par verset, le rendu d'une page avec sa police et l'écran de configuration
  n'ont jamais été exercés sur un téléphone.
- **La CI ne couvre pas ce document.** `verifier_identifiants_qf.py` exige de vrais identifiants et
  n'est donc pas un portail d'intégration continue — il se lance à la main, après une rotation.
