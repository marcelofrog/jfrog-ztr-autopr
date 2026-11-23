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
$EDITOR .env                              # set JFROG_FQDN and JFROG_SERVER_ID
export GITHUB_REPOSITORY=<owner>/<repo>   # the only repo allowed to use the OIDC mapping
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

Plus the JFrog Project `javasample`, a new user `javasample-admin` who is its Project Admin (a generated
password is printed once), the AppTrust application `sample-app`, and the GitHub OIDC provider
`github-actions` with an identity mapping that gives workflows of `GITHUB_REPOSITORY` a short-lived token
with the project role `Developer`.

## 2. Build locally

```bash
./jfrog-setup/local-build.sh              # mvn verify + docker build, through JFrog
./jfrog-setup/local-build.sh --no-docker  # Maven only
java -jar target/sample-app.jar           # :8080 (override with PORT)
```

`local-build.sh` reads the host and server id from the root `.env`, mints a **short-lived token with the CLI**
(`jf atc`) for Maven and the Docker login, and never writes it to disk. Equivalent manual commands, with the
values taken from the root `.env` (`$JFROG_FQDN`, and `javasample` as the project key):

```bash
mvn -s ci/settings.xml verify     # needs JF_URL=https://$JFROG_FQDN, JF_MAVEN_REPO=javasample-maven-virtual, JF_USER, JF_ACCESS_TOKEN
docker build --build-arg BASE_REGISTRY=$JFROG_FQDN/javasample-docker-virtual -t sample-app .
```

## 3. CI

`.github/workflows/ci.yml` authenticates with OIDC (`jfrog/setup-jfrog-cli`, `id-token: write`), so it needs
**no secrets**, only repository variables `JF_URL` and `JF_PROJECT_KEY` (printed at the end of `setup.sh`).
It runs `mvn verify`, builds the image
from the JFrog base image, and on `main` deploys the jar and pushes
`<host>/javasample-docker-dev-local/sample-app:{sha,latest}`.

Note: the Actions runner's JDK and Maven themselves are runner tools, not project dependencies.
