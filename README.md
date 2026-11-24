# sample-app

Lean Java 21 / Maven sample: a tiny JSON HTTP service (`/hello?name=Jane`, `/health`).

Libraries: Jackson (+ JSR-310), Guava, Commons Lang 3, SLF4J + Logback, JUnit 5, AssertJ.

All Maven dependencies/plugins and Docker base images come from JFrog Artifactory, and the
image and jar are published to JFrog.

## 1. Provision JFrog (once)

The JFrog FQDN and the JFrog CLI server id are **configuration parameters**: set `JFROG_FQDN` and
`JFROG_SERVER_ID` in the root `.env` (git-ignored; `jfrog-setup/config.env` loads it). Every script and command below takes them from there. No
token is configured: authentication is your CLI web-login session. See
[`jfrog-setup/README.md`](jfrog-setup/README.md) for the manual prerequisites.

```bash
jf login                                  # web login as a platform admin; note the Server ID (jf c show)
cp .env.sample .env                       # create your git-ignored .env from the template
$EDITOR .env                              # set JFROG_FQDN, JFROG_SERVER_ID, GITHUB_REPOSITORY (owner/repo: the only repo allowed to use OIDC)
DRY_RUN=1 ./jfrog-setup/setup.sh          # preview
./jfrog-setup/setup.sh                    # project + admin user + repos + OIDC + AppTrust application
./jfrog-setup/teardown.sh                 # reset the demo (deletes all of the above; --yes skips the prompt)
```

Creates, all prefixed with the project key (`javasample` as shipped, set as `PROJECT_KEY` in the root `.env`):

| Purpose | Repository |
|---|---|
| Maven resolve + deploy | `javasample-maven-virtual` = patch-local + dev-local + prod-local + remote |
| Maven | `javasample-maven-patch-local` (JFrog ZTR patches, resolved first), `javasample-maven-dev-local`, `javasample-maven-prod-local`, `javasample-maven-remote` (Maven Central) |
| Docker pull | `javasample-docker-virtual` = dev-local + prod-local + remote |
| Docker | `javasample-docker-dev-local` (CI pushes here), `javasample-docker-prod-local`, `javasample-docker-remote` (Docker Hub) |

Every repository has Xray indexing on, and so do the builds CI publishes to the project's build repository
(`<project>-build-info`). The Maven remote also has JFrog Curation on.

Plus the JFrog Project `javasample`, a new user `javasample-admin` who is its Project Admin (a generated
password is printed once), the AppTrust application `sample-app`, and a CI user `github-ci` with the project roles
`Developer`, `Contributor` and `Release Manager`. The GitHub OIDC provider `<owner>/<repo>@github` and its identity
mapping are created by the Frogbot GitHub integration in JFrog (set up in the UI; the mapping must issue tokens for
`github-ci`), not by this project.

## 2. Build locally

```bash
./jfrog-setup/local-build.sh              # jf mvn verify + docker build, through JFrog
./jfrog-setup/local-build.sh --no-docker  # Maven only
java -jar target/sample-app.jar           # :8080 (override with PORT)
```

`local-build.sh` reads the host and server id from the root `.env`. Maven runs as `jf mvn`, which reads
`.jfrog/projects/maven.yaml` (written by `setup.sh`, git-ignored) and uses your `jf login` session.
There is no `settings.xml`. Docker login uses a **short-lived token minted with the CLI** (`jf atc`);
it is never written to disk. Equivalent manual commands, with the values taken from the root `.env`
(`$JFROG_FQDN`, and `javasample` as the project key):

```bash
jf mvn -B verify              # uses .jfrog/projects/maven.yaml: the Maven virtual for releases and snapshots
docker build --build-arg BASE_REGISTRY=$JFROG_FQDN/javasample-docker-virtual -t sample-app .
```

## 3. CI

`.github/workflows/ci.yml` authenticates with OIDC (`jfrog/setup-jfrog-cli`, `id-token: write`), so it needs
**no secrets**. `setup.sh` sets the repository variables `JF_URL`, `JF_PROJECT_KEY` and `JF_OIDC_AUDIENCE` with the
`gh` CLI. The workflow sets the OIDC provider itself: `JF_OIDC_PROVIDER` is `<owner>/<repo>@github`.
It runs `jf mvn verify` on pull requests and `jf mvn deploy` on `main` (the workflow writes a Maven config for
the OIDC CLI server; releases and snapshots come from the Maven virtual repo). Both pass
`--build-name` (the repository name), `--build-number` (the run number) and `--project`, so the build is
recorded as build-info (the Maven module). The same job then builds the image from the JFrog base image, and on
`main` pushes `<host>/javasample-docker-dev-local/sample-app:{sha,latest}` and adds it to the build as the
`sample-app-image` Docker module (`jf rt build-docker-create`, from the pushed manifest digest). Pull requests
build the image but do not push it, so they have no Docker module. Last, the job adds git info
(`jf rt build-add-git`) and the environment (`jf rt build-collect-env`), then publishes the build
(`jf rt build-publish`, with the run URL; variables whose names match
`*password*;*psw*;*secret*;*key*;*token*;*auth*` are excluded).

Maven, Docker and the publish run in a single job on purpose: the CLI keeps the partial build-info on the
runner until `build-publish`.

Note: the Actions runner's JDK and Maven themselves are runner tools, not project dependencies.
