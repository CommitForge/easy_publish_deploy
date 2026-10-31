FROM maven:3.9.9-eclipse-temurin-23 AS build

ARG BACKEND_SOURCE_DIR=./repos/easy_publish_backend
ARG CLI_SOURCE_DIR=./repos/easy_publish_cli
WORKDIR /src

# Copy backend source from the deploy workspace (after sync checkout).
COPY ${BACKEND_SOURCE_DIR}/pom.xml ./pom.xml
COPY ${BACKEND_SOURCE_DIR}/src ./src
COPY ${BACKEND_SOURCE_DIR}/node ./node
COPY ${CLI_SOURCE_DIR}/package*.json ./easy_publish_cli/
COPY ${CLI_SOURCE_DIR}/izipub.js ./easy_publish_cli/izipub.js
COPY ${CLI_SOURCE_DIR}/lib ./easy_publish_cli/lib

RUN mvn -DskipTests package && \
    APP_JAR="$(find target -maxdepth 1 -type f -name '*.jar' ! -name '*original*' | head -n 1)" && \
    test -n "$APP_JAR" && \
    cp "$APP_JAR" /tmp/app.jar

FROM eclipse-temurin:25-jre-jammy

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=24

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      gnupg \
      fontconfig \
      fonts-dejavu \
      libfreetype6 \
      libxrender1 \
      libxext6 && \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app/node
COPY --from=build /src/node/package*.json ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi
# The staged node directory contains only package metadata and executable
# JavaScript modules, including the .mjs dashboard/analyzer scripts.
COPY --from=build /src/node/ ./

# Node commands run from both /app and /app/node. An explicit environment
# value gives every command the same self-contained CLI location.
WORKDIR /app/easy_publish_cli
COPY --from=build /src/easy_publish_cli/package*.json ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi
COPY --from=build /src/easy_publish_cli/izipub.js ./
COPY --from=build /src/easy_publish_cli/lib ./lib

WORKDIR /app
COPY --from=build /tmp/app.jar /app/app.jar
COPY --from=build /src/src/main/resources/application.properties /app/application.properties

ENV JAVA_TOOL_OPTIONS="-Djava.awt.headless=true"
ENV BACKEND_INTERNAL_PORT=8081
ENV APP_CONFIG_PATH=/app/application.properties
ENV EASY_PUBLISH_CLI_DIR=/app/easy_publish_cli

EXPOSE 8081

ENTRYPOINT ["/bin/bash","-lc","exec java -jar /app/app.jar --server.port=${BACKEND_INTERNAL_PORT:-8081} --spring.config.additional-location=file:${APP_CONFIG_PATH}"]
