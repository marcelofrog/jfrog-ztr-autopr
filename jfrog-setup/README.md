# JFrog setup

Scripts that provision (and reset) everything the sample app's CI needs on the JFrog Platform.

| Script | What it does |
|---|---|
| `setup.sh` | Creates the project, a project-admin user, 9 repositories, a CI user with project roles, and the AppTrust application. The OIDC provider `<owner>/<repo>@github` and its identity mapping come from the Frogbot GitHub integration, not from this script (see step 4). Safe to re-run: existing resources are skipped. |
| `teardown.sh` | Deletes all of the above, **including the artifacts in the repositories and the builds CI published**, to reset the demo. The OIDC provider is left in place, because Frogbot owns it. |
| `local-build.sh` | Builds, tests and containerizes the app on your machine through JFrog, using a short-lived token minted by the CLI. |
| `config.env` | **Settings for all scripts**, committed to git: project key, app key, OIDC, upstream URLs, and so on, each with a default. Every script loads the root `.env` through it, and a value in `.env` **overrides** the same variable in your shell environment. |
| `../.env.sample` (repository root) | **Committed template** for `.env`. Contains no secrets. |
| `../.env` (repository root) | **Git-ignored, never commit.** Your copy of `.env.sample`. Holds the instance secrets `JFROG_FQDN` and `JFROG_SERVER_ID`, plus the names `PROJECT_KEY`, `PROJECT_NAME`, `APP_KEY` and `APP_NAME`. |
| `lib.sh` | Shared helpers. Not run directly. |

## Where the connection values come from

Every script reads these from `config.env`, which takes the instance values and the project and application names from the root `.env`. Nothing is hardcoded, and there is **no token to configure or pass**:

| Value | Config parameter | Used for |
|---|---|---|
| JFrog FQDN (e.g. `acme.jfrog.io`) | `JFROG_FQDN` | The base URL (`https://$JFROG_FQDN`), the Docker registry host, the Maven mirror URL, the `JF_URL` GitHub variable that `setup.sh` prints. |
| Instance name as defined in the JFrog CLI | `JFROG_SERVER_ID` | Passed as `--server-id` to **every** `jf` and `jf api` call. |
| Credentials | *(none, from `jf login`)* | The CLI's web-login session authenticates every call. Where a raw token is unavoidable (local Maven and Docker login), the scripts mint a short-lived one with `jf atc` for that run only. |

On start, every script checks that the CLI server named by `JFROG_SERVER_ID` exists **and** points at `JFROG_FQDN`. If not, it stops. It never falls back to another server.

## What gets created

With the project key from `.env` (`javasample` as shipped):

| Type | Name | Notes |
|---|---|---|
| Project | `javasample` | |
| User | `javasample-admin` | Not a platform admin. `Project Admin` of `javasample` only. |
| Maven virtual | `javasample-maven-virtual` | Resolve and deploy URL. Contains patch-local, dev-local, prod-local, remote. Deploys go to dev-local. |
| Maven local | `javasample-maven-dev-local` (env `DEV`), `javasample-maven-prod-local` (env `PROD`) | |
| Maven local (patch) | `javasample-maven-patch-local` | Local patch repo for JFrog ZTR. No environment. Listed **first** in the Maven virtual, so patched versions win over Maven Central. |
| Maven remote | `javasample-maven-remote` | Proxies Maven Central. Xray indexing and JFrog Curation are both on. |
| Maven project config | `.jfrog/projects/maven.yaml` (repo root, git-ignored) | Read by `jf mvn`. `local-build.sh` uses the file this script writes; CI writes its own for the OIDC server. Resolves and deploys releases and snapshots through the Maven virtual. Machine-specific (it names your CLI server id). Plain `mvn` does not read it, and there is no `settings.xml`. |
| Docker virtual | `javasample-docker-virtual` | Pull URL for base images. Contains dev-local, prod-local, remote. |
| Docker local | `javasample-docker-dev-local` (env `DEV`), `javasample-docker-prod-local` (env `PROD`) | CI pushes images to dev-local. |
| Docker remote | `javasample-docker-remote` | Proxies Docker Hub. |
| CI user | `github-ci` (`CI_USER`) | Not a platform admin. Gets the project roles in `CI_PROJECT_ROLES` (default `Developer`, `Contributor`, `Release Manager`) on `javasample`. A random password is set and not kept: the user is meant to get tokens through OIDC. |
| OIDC provider and identity mapping | `<owner>/<repo>@github` | **Not created here.** The Frogbot GitHub integration creates them when the repository is linked in the JFrog UI. `setup.sh` neither creates nor looks for them. The mapping must issue tokens for the CI user above. |
| AppTrust application | `sample-app` | In project `javasample`. |

Every repository is created with Xray indexing on (`xrayIndex`). A repository that already exists is updated in place when indexing is still off. Only the Maven remote has Curation (`curated`).

**Builds.** CI publishes build-info to the project's build repository, `<PROJECT_KEY>-build-info`, which JFrog creates with the project. Xray scans builds, not the repository, so `setup.sh` also turns on build indexing for the project: `PUT /xray/api/v1/binMgr/default/builds?projectKey=<PROJECT_KEY>` with the include pattern `BUILD_INDEX_PATTERN` (default `*/**`, every build of the project). Patterns work before the first build exists. The API cannot read patterns back, so a run where the build is not yet in the indexed list sends the update again; it is idempotent. The update replaces the project's build indexing rules, so set `BUILD_INDEX_PATTERN` if you want something narrower. Policies and watches (what Xray does with the results) are not created by this script.

## Before you run it (manual steps)

### 1. Tools on your machine

- **Bash**, **`jq`**, and **`openssl`** (used to generate the admin password).
- **JDK 21 and Maven.** `jf mvn` needs both. If `java` or `mvn` is not on your `PATH`, or `JAVA_HOME` points at a missing JDK, `setup.sh` searches for the binaries and writes `JAVA_HOME` and `M2_HOME` into the root `.env`. `M2_HOME` is the Maven directory that contains `bin` and `lib`. Every script then prepends those `bin` directories to `PATH`.
- **JFrog CLI (`jf`)** with the `apptrust` command. Check with `jf apptrust --help`. If it's missing, upgrade the CLI: <https://jfrog.com/getcli>.
- **GitHub CLI (`gh`)**, logged in with `gh auth login` as an admin of `GITHUB_REPOSITORY`. `setup.sh` uses it to set the repository variables. Check with `gh auth status`.

### 2. A JFrog Platform that supports this

Verify these on your JFrog instance. The script can't fix them for you.

- **AppTrust is enabled.** It needs the right license/subscription. Check with `jf apptrust ping --server-id <id>`.
- **Projects are available.** Projects require a license that includes them.
- **The `DEV` and `PROD` global environments exist.** They are the platform defaults. Check with:
  `jf api /access/api/v1/environments`.
  If yours are named differently, change `DEV_ENVIRONMENT` / `PROD_ENVIRONMENT` in `config.env`, or set them to `""` to skip environment assignment.
- **You can create internal users.** If the platform is SSO/SAML-only with internal users disabled, creating `javasample-admin` fails. Either enable internal users or set `PROJECT_ADMIN_USER` to a user that already exists (the create step is skipped when the user exists).
- **Docker registry access works for your instance.** The workflow pushes to `<host>/javasample-docker-dev-local/sample-app` (the *repository path* method). This is the default on JFrog SaaS. On self-hosted instances, the Docker registry must be exposed through your reverse proxy with that method enabled.
- **Self-hosted only:** JFrog must reach `repo1.maven.org` and `registry-1.docker.io` (outbound HTTPS, through your proxy if you use one), because the remote repositories fetch from them.

### 3. Log the JFrog CLI in with web login, as a platform admin

The setup creates users, projects, OIDC integrations and repositories, so the account you log in with must be a **platform admin**. No access token is needed. Log in with a browser:

```bash
jf login        # opens your browser; enter https://<your FQDN> when asked, and pick a server id
jf c show       # find the "Server ID" you just created
```

Create your `.env` from the template, then put the two values in it. This is the only place they are set:

```bash
cp .env.sample .env   # run from the repository root; .env is git-ignored
```

```bash
# .env (repository root)
JFROG_FQDN=acme.jfrog.io        # host of the instance (no https://)
JFROG_SERVER_ID=acme            # the "Server ID" shown by `jf c show`
```

The scripts print `Server: <id> (<fqdn>)` when they start so you can confirm the target. If the session expires (a `401`), run `jf login` again for the same server id. `jf login` needs a browser on the machine running the scripts.

### 4. Know the GitHub repository

You need the repository that will run CI, in `owner/repo` form. Only that repository can use the OIDC mapping. Create it on GitHub first if it doesn't exist yet.

The OIDC provider for it is named `<owner>/<repo>@github`. The Frogbot GitHub integration creates it: install the Frogbot app on the repository and link the repository in the JFrog UI. This project does not configure Frogbot. `setup.sh` does not create, check or change the provider or its identity mapping. In the Frogbot integration, make the identity mapping issue tokens for the CI user (`CI_USER`, default `github-ci`), which `setup.sh` creates and gives the project roles.

### 5. Check for name collisions

The project key (`javasample` by default) must be unique on the platform. It must be 2-32 lowercase alphanumeric characters. Change `PROJECT_KEY` in the root `.env` if it's taken. All repository names derive from it.

The OIDC audience (`jfrog-github`) must be the same in `OIDC_AUDIENCE` (`config.env`) and `JF_OIDC_AUDIENCE` (`.github/workflows/ci.yml`). If you change one, change the other.

### 6. Optional: Docker Hub credentials

Docker Hub throttles anonymous pulls. If the base-image pull through `javasample-docker-remote` is rate-limited, add Docker Hub credentials to that remote repository (*Repositories > javasample-docker-remote > Advanced*). The script doesn't set them, to avoid handling your Docker Hub secrets.

## Run it

```bash
# Everything comes from the root .env (JFROG_FQDN, JFROG_SERVER_ID, PROJECT_KEY, GITHUB_REPOSITORY, ...).
# Create it first: cp .env.sample .env, then fill it in. Every script refuses to run without it.
cd jfrog-setup

DRY_RUN=1 ./setup.sh     # preview the requests; changes nothing, needs no server or login (still needs .env)
./setup.sh               # create everything
```

To change a setting, edit `.env` (for example `PROJECT_KEY`, `PROJECT_ADMIN_EMAIL`, `PROJECT_ADMIN_PASSWORD`). A value in `.env` always wins over a variable exported in your shell, so exporting one has no effect while the line is in `.env`. Delete or comment out the line to use the environment or the default instead.

If you don't set `PROJECT_ADMIN_PASSWORD`, a password is generated and **printed once** at the end, in a yellow warning box. Save it.

Output is color-coded (green created, dim unchanged, red errors, yellow warnings) and every resource gets one status line. Colors only appear in a terminal. Set `NO_COLOR=1` for plain text or `FORCE_COLOR=1` to keep colors when piping. Without a UTF-8 locale the boxes fall back to ASCII.

## After it runs (manual steps)

1. **GitHub repository variables are set by `setup.sh`** with the `gh` CLI, on `GITHUB_REPOSITORY`. No secrets are created: the workflow authenticates with OIDC.

   | Variable | Value |
   |---|---|
   | `JF_URL` | `https://<JFROG_FQDN>` |
   | `JF_PROJECT_KEY` | `PROJECT_KEY` from `.env` |
   | `JF_OIDC_AUDIENCE` | `OIDC_AUDIENCE` from `.env` (the audience the OIDC provider accepts) |

   The workflows set the provider name themselves (`JF_OIDC_PROVIDER: ${{ github.repository }}@github`), so no variable is needed for it. A `JF_OIDC_PROVIDER` variable left over from an earlier run is ignored.

   A variable that already has the right value is left alone. To change one by hand, use `gh variable set NAME --body VALUE -R owner/repo`.

2. **Check the CI roles can do their job.** The CI user has the project roles in `CI_PROJECT_ROLES` in `config.env` (default `Developer,Contributor,Release Manager`). Together they must be able to read the two virtual repos, deploy to the two dev-local repos, and publish build-info (the `jf rt build-publish` step writes to the project's `<project>-build-info` repository). If the first CI run gets a 403, open *Administration > Projects > javasample > Roles*, or change `CI_PROJECT_ROLES` to roles that have the permissions and re-run `setup.sh`: the role assignment is applied again on every run.

3. **Check the admin user.** Log in as `javasample-admin` and confirm it can see the project. Change the generated password if you like.

4. **Optionally build locally.** `./local-build.sh` runs `jf mvn verify` with the Maven config this script wrote, then builds the image (`--no-docker` skips Docker). Docker login uses a short-lived token from the CLI.

5. **Run the workflow.** Push to `main`. The first run proves OIDC login, Maven resolution through the virtual repo, the Maven deploy, the build-info publish (visible under *Application > Builds* in the project, named after the repository, with a Maven module and, on `main`, a `sample-app-image` Docker module) and the Docker pull and push.

## Reset the demo

```bash
DRY_RUN=1 ./teardown.sh   # list what would be deleted
./teardown.sh             # asks you to type the project key
./teardown.sh --yes       # no prompt
./setup.sh                # recreate a clean environment
```

Teardown removes the AppTrust app, every build CI published to the project (all build numbers; they would otherwise outlive the project in `<project>-build-info`), all repositories **and their contents**, the admin user, the CI user, and the project, in that order. It does not touch the OIDC provider or its identity mapping, which belong to the Frogbot integration. The AppTrust app can't be deleted while it still has versions. Delete those first with `jf apptrust version-delete` if teardown reports that.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Set JFROG_FQDN and JFROG_SERVER_ID` | Fill in both values in the root `.env`. |
| `JFrog CLI server '<id>' not found` | Run `jf login` and use the server id from the root `.env`, or fix `JFROG_SERVER_ID`. |
| `CLI server ... points at ... but JFROG_FQDN is ...` | The CLI server id and the FQDN refer to different instances. Fix one of them. |
| `401` / `Hint: session expired` | Run `jf login` again for the same server id. |
| `403` on create calls | The account you logged in with isn't a platform admin. |
| Project create returns `400` | Invalid project key (uppercase, too long/short, hyphen at the ends). |
| Repo create fails with a project/key error | Repository names must start with `<PROJECT_KEY>-`. Don't rename them without the prefix. |
| `jf apptrust` not found or app create fails | CLI too old, or AppTrust isn't enabled on the instance. |
| CI: OIDC token exchange fails, or the token can't read or deploy | The Frogbot GitHub integration isn't set up for this repository, `GITHUB_REPOSITORY` doesn't match the provider name `<owner>/<repo>@github` exactly (case included), or its identity mapping doesn't issue tokens for `CI_USER`. Fix it in the JFrog UI. |
| CI: OIDC token exchange fails | `GITHUB_REPOSITORY` doesn't match the running repo exactly, the audience differs between `config.env` and `ci.yml`, or the workflow lacks `id-token: write`. |
| CI: Docker pull of the base image fails (`manifest unknown`) | Docker Hub remote can't reach `library/eclipse-temurin`. Check outbound access and Docker Hub credentials. |
| Run is a pull request from a fork | Forks get no OIDC token, so JFrog steps fail by design. |
