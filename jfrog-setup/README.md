# JFrog setup

Scripts that provision (and reset) everything the sample app's CI needs on the JFrog Platform.

| Script | What it does |
|---|---|
| `setup.sh` | Creates the project, a project-admin user, 9 repositories, the GitHub OIDC provider + identity mapping, and the AppTrust application. Safe to re-run: existing resources are skipped. |
| `teardown.sh` | Deletes all of the above, **including the artifacts in the repositories**, to reset the demo. |
| `local-build.sh` | Builds, tests and containerizes the app on your machine through JFrog, using a short-lived token minted by the CLI. |
| `config.env` | **Settings for all scripts**, committed to git: project key, app key, OIDC, upstream URLs, and so on, each with a default. It loads the root `.env` and lets environment variables override any value. |
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
| Maven remote | `javasample-maven-remote` | Proxies Maven Central. |
| Docker virtual | `javasample-docker-virtual` | Pull URL for base images. Contains dev-local, prod-local, remote. |
| Docker local | `javasample-docker-dev-local` (env `DEV`), `javasample-docker-prod-local` (env `PROD`) | CI pushes images to dev-local. |
| Docker remote | `javasample-docker-remote` | Proxies Docker Hub. |
| OIDC provider | `github-actions` | Issuer `https://token.actions.githubusercontent.com`, audience `jfrog-github`. |
| OIDC identity mapping | `github-ci` | Only workflows of `GITHUB_REPOSITORY` match. They get a 1-hour token with project role `Developer` on `javasample`. |
| AppTrust application | `sample-app` | In project `javasample`. |

## Before you run it (manual steps)

### 1. Tools on your machine

- **Bash**, **`jq`**, and **`openssl`** (used to generate the admin password).
- **JFrog CLI (`jf`)** with the `apptrust` command. Check with `jf apptrust --help`. If it's missing, upgrade the CLI: <https://jfrog.com/getcli>.

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

### 5. Check for name collisions

The project key (`javasample` by default) must be unique on the platform. It must be 2-32 lowercase alphanumeric characters. Change `PROJECT_KEY` in the root `.env` if it's taken. All repository names derive from it.

The OIDC audience (`jfrog-github`) must be the same in `OIDC_AUDIENCE` (`config.env`) and `JF_OIDC_AUDIENCE` (`.github/workflows/ci.yml`). If you change one, change the other.

### 6. Optional: Docker Hub credentials

Docker Hub throttles anonymous pulls. If the base-image pull through `javasample-docker-remote` is rate-limited, add Docker Hub credentials to that remote repository (*Repositories > javasample-docker-remote > Advanced*). The script doesn't set them, to avoid handling your Docker Hub secrets.

## Run it

```bash
cd jfrog-setup
# JFROG_FQDN and JFROG_SERVER_ID are read from the root .env (see "Where the connection values come from")
export GITHUB_REPOSITORY=<owner>/<repo>

DRY_RUN=1 ./setup.sh     # preview the requests; changes nothing, needs no server or login
./setup.sh               # create everything
```

Optional overrides, for example:

```bash
PROJECT_KEY=myproj PROJECT_ADMIN_EMAIL=me@acme.com PROJECT_ADMIN_PASSWORD='...' ./setup.sh
```

If you don't set `PROJECT_ADMIN_PASSWORD`, a password is generated and **printed once** at the end. Save it.

## After it runs (manual steps)

1. **Set GitHub repository variables** (Settings > Secrets and variables > Actions > *Variables*). No secrets are needed.

   | Variable | Value |
   |---|---|
   | `JF_URL` | `https://<JFROG_FQDN>` (`setup.sh` prints the exact value from `config.env`) |
   | `JF_PROJECT_KEY` | `javasample` (or your `PROJECT_KEY`) |
   | `JF_OIDC_PROVIDER` | Only if you changed `OIDC_PROVIDER_NAME` from `github-actions` |

2. **Check the CI role can do its job.** The `Developer` project role must be able to read the two virtual repos and deploy to the two dev-local repos. If the first CI run gets a 403, open *Administration > Projects > javasample > Roles*, or set `CI_PROJECT_ROLE` in `config.env` to a role that has the permissions (then run teardown and setup, or delete the `github-ci` mapping and re-run `setup.sh`).

3. **Check the admin user.** Log in as `javasample-admin` and confirm it can see the project. Change the generated password if you like.

4. **Optionally build locally.** `./local-build.sh` mints a short-lived token with the CLI and runs the Maven build and Docker build through JFrog (`--no-docker` skips Docker).

5. **Run the workflow.** Push to `main`. The first run proves OIDC login, Maven resolution through the virtual repo, the Maven deploy, and the Docker pull and push.

## Reset the demo

```bash
DRY_RUN=1 ./teardown.sh   # list what would be deleted
./teardown.sh             # asks you to type the project key
./teardown.sh --yes       # no prompt
./setup.sh                # recreate a clean environment
```

Teardown removes the AppTrust app, OIDC mapping and provider, all repositories **and their contents**, the admin user, and the project, in that order. The AppTrust app can't be deleted while it still has versions. Delete those first with `jf apptrust version-delete` if teardown reports that.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Set JFROG_FQDN and JFROG_SERVER_ID` | Fill in both values in the root `.env` (or export them). |
| `JFrog CLI server '<id>' not found` | Run `jf login` and use the server id from the root `.env`, or fix `JFROG_SERVER_ID`. |
| `CLI server ... points at ... but JFROG_FQDN is ...` | The CLI server id and the FQDN refer to different instances. Fix one of them. |
| `401` / `Hint: session expired` | Run `jf login` again for the same server id. |
| `403` on create calls | The account you logged in with isn't a platform admin. |
| Project create returns `400` | Invalid project key (uppercase, too long/short, hyphen at the ends). |
| Repo create fails with a project/key error | Repository names must start with `<PROJECT_KEY>-`. Don't rename them without the prefix. |
| `jf apptrust` not found or app create fails | CLI too old, or AppTrust isn't enabled on the instance. |
| CI: OIDC token exchange fails | `GITHUB_REPOSITORY` doesn't match the running repo exactly, the audience differs between `config.env` and `ci.yml`, or the workflow lacks `id-token: write`. |
| CI: Docker pull of the base image fails (`manifest unknown`) | Docker Hub remote can't reach `library/eclipse-temurin`. Check outbound access and Docker Hub credentials. |
| Run is a pull request from a fork | Forks get no OIDC token, so JFrog steps fail by design. |
