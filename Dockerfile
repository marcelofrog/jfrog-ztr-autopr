# The jar is built first (`jf mvn -B verify`), so the image only needs a JRE.
# The base image MUST come from JFrog: pass the Docker virtual repo as a build arg, e.g.
#   docker build --build-arg BASE_REGISTRY=<JFROG_FQDN from the root .env>/javasample-docker-virtual -t sample-app .
# (jfrog-setup/local-build.sh does this for you)
ARG BASE_REGISTRY
FROM ${BASE_REGISTRY}/eclipse-temurin:21-jre

RUN useradd --system --uid 10001 appuser
WORKDIR /app
COPY target/sample-app.jar app.jar
USER 10001
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
